import Foundation
import Darwin

/// One reading of the machine's memory state.
public struct VMSample: Sendable, Equatable {
    /// Memory that can be handed to a new allocation without paging anything out.
    public let availableBytes: UInt64
    /// Cumulative pages written to swap since boot. Monotonic, so only its delta matters.
    public let pageoutPages: UInt64

    public init(availableBytes: UInt64, pageoutPages: UInt64) {
        self.availableBytes = availableBytes
        self.pageoutPages = pageoutPages
    }
}

/// `host_statistics64` wrapper. The only part of the watchdog that talks to Mach, kept
/// separate so the trigger logic can be tested against synthetic readings.
public enum MachMemory {
    /// Deliberately conservative. The obvious formula — `free + inactive + purgeable` —
    /// is wrong on Darwin: `free_count` already *includes* `speculative_count`, which is
    /// why Apple's own `vm_stat` subtracts speculative before printing "Pages free".
    /// Copying the naive version would over-count by exactly the pool we mean to exclude,
    /// and the watchdog is supposed to undersell how much room is left, never oversell it.
    public static func sample() -> VMSample? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        // Saturating: free >= speculative by construction, but a trap here would crash
        // mako mid-render over an arithmetic edge case that does not matter.
        let free = UInt64(stats.free_count) > UInt64(stats.speculative_count)
            ? UInt64(stats.free_count) - UInt64(stats.speculative_count) : 0
        let reclaimable = free + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        return VMSample(availableBytes: reclaimable * UInt64(pageSize),
                        pageoutPages: stats.pageouts)
    }
}

/// The trigger logic, as a pure state machine: feed it readings, get back a reason the
/// first time one crosses a red line and `nil` forever after.
public struct MemoryPressure: Sendable {
    public let floorBytes: UInt64
    public let swapDeltaPages: UInt64
    private var previousPageouts: UInt64?
    private var fired = false

    public init(floorBytes: UInt64, swapDeltaPages: UInt64) {
        self.floorBytes = floorBytes
        self.swapDeltaPages = swapDeltaPages
    }

    public mutating func evaluate(_ sample: VMSample) -> String? {
        defer { previousPageouts = sample.pageoutPages }
        guard !fired else { return nil }

        if sample.availableBytes < floorBytes {
            fired = true
            return "available memory fell to \(megabytes(sample.availableBytes)) MB, "
                + "below the \(megabytes(floorBytes)) MB floor"
        }
        // A swap storm is the real early warning on Apple silicon: the machine is still
        // reporting free pages while it is already paging out hard, and by the time
        // "available" collapses the whole system has stopped responding.
        if let previous = previousPageouts, sample.pageoutPages > previous {
            let delta = sample.pageoutPages - previous
            if delta > swapDeltaPages {
                fired = true
                return "swap storm: \(delta) pages written to swap in one interval "
                    + "(over the \(swapDeltaPages) page limit)"
            }
        }
        return nil
    }
}

/// Polls memory while a heavyweight child renders, and SIGKILLs its process group the
/// instant a red line is crossed.
///
/// This lives in the parent on purpose. The sidecar arms its own in-process guard, but a
/// process that is thrashing may not get scheduled often enough to run it — the killer
/// has to be somebody who is not the one running out of memory. In practice the child's
/// guard usually wins the race (its floor is higher), and this is the backstop.
///
/// SIGKILL rather than SIGTERM is also deliberate: a graceful shutdown still has to
/// unwind gigabytes of allocations, which is precisely what there is no room for.
public actor MemoryWatchdog {
    /// Low by design. This is not "the model needs 2 GB" — it is the point past which
    /// macOS stops degrading and starts freezing, and being brutal there is cheaper than
    /// a multi-minute hang.
    public static let defaultFloorMB: UInt64 = 2000
    /// 80 000 × 16 KiB ≈ 1.25 GiB paged out inside one poll interval.
    public static let defaultSwapDeltaPages: UInt64 = 80_000

    public static var isDisabled: Bool {
        ProcessInfo.processInfo.environment["MAKO_NO_OOMGUARD"] != nil
    }

    /// `MAKO_OOM_FLOOR_MB` overrides the floor — used by the forced-trigger test, which
    /// sets it absurdly high to prove the kill path works.
    public static var configuredFloorMB: UInt64 {
        guard let raw = ProcessInfo.processInfo.environment["MAKO_OOM_FLOOR_MB"],
              let value = UInt64(raw) else { return defaultFloorMB }
        return value
    }

    private var pressure: MemoryPressure
    private let interval: Duration
    private let sampler: @Sendable () -> VMSample?
    private var loop: Task<Void, Never>?
    private var stopped = false

    public init(
        floorMB: UInt64 = MemoryWatchdog.configuredFloorMB,
        swapDeltaPages: UInt64 = MemoryWatchdog.defaultSwapDeltaPages,
        interval: Duration = .milliseconds(250),
        sampler: @escaping @Sendable () -> VMSample? = { MachMemory.sample() }
    ) {
        self.pressure = MemoryPressure(floorBytes: floorMB * 1024 * 1024,
                                       swapDeltaPages: swapDeltaPages)
        self.interval = interval
        self.sampler = sampler
    }

    /// Starts polling. `onTrigger` runs once, on the first crossing, and polling stops.
    ///
    /// A start that arrives after `stop()` is ignored rather than honoured. The runner
    /// starts the watchdog from a detached task once the child's pgid is known, so a
    /// child that dies almost immediately can get its `stop()` in first — and a loop
    /// started afterwards would go on polling with a pgid the kernel is free to reuse.
    public func start(onTrigger: @escaping @Sendable (String) -> Void) {
        guard loop == nil, !stopped else { return }
        loop = Task { [interval, sampler] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let sample = sampler() else { continue }
                if let reason = self.evaluate(sample) {
                    onTrigger(reason)
                    return
                }
            }
        }
    }

    public func stop() {
        stopped = true
        loop?.cancel()
        loop = nil
    }

    private func evaluate(_ sample: VMSample) -> String? {
        pressure.evaluate(sample)
    }
}

private func megabytes(_ bytes: UInt64) -> String {
    String(bytes / (1024 * 1024))
}
