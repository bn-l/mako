import Foundation
import Testing
@testable import TTSHarnessCore

/// Unit tests for the watchdog's trigger logic, driven by synthetic readings so nothing
/// here depends on how much memory the test machine happens to have free.
@Suite("MemoryPressure")
struct MemoryPressureTests {
    private let gigabyte: UInt64 = 1024 * 1024 * 1024

    private func pressure(floorMB: UInt64 = 2000, swapDeltaPages: UInt64 = 80_000)
        -> MemoryPressure {
        MemoryPressure(floorBytes: floorMB * 1024 * 1024, swapDeltaPages: swapDeltaPages)
    }

    @Test("plenty of memory, nothing happens")
    func quietWhenHealthy() {
        var monitor = pressure()
        for step in 0..<10 {
            let sample = VMSample(availableBytes: 8 * gigabyte,
                                  pageoutPages: UInt64(step) * 100)
            #expect(monitor.evaluate(sample) == nil)
        }
    }

    @Test("crossing the floor fires, and names the numbers")
    func firesOnFloor() {
        var monitor = pressure(floorMB: 2000)
        #expect(monitor.evaluate(VMSample(availableBytes: 4 * gigabyte,
                                          pageoutPages: 0)) == nil)
        let reason = monitor.evaluate(
            VMSample(availableBytes: 1024 * 1024 * 1024, pageoutPages: 0))
        #expect(reason?.contains("1024 MB") == true)
        #expect(reason?.contains("2000 MB") == true)
    }

    /// The kill is a one-shot: firing twice would mean SIGKILLing a pid that may already
    /// have been reused.
    @Test("it fires exactly once")
    func firesOnce() {
        var monitor = pressure(floorMB: 2000)
        let low = VMSample(availableBytes: 100 * 1024 * 1024, pageoutPages: 0)
        #expect(monitor.evaluate(low) != nil)
        #expect(monitor.evaluate(low) == nil)
        #expect(monitor.evaluate(low) == nil)
    }

    /// The real early warning on Apple silicon: the machine still reports free pages
    /// while it is already paging out hard.
    @Test("a swap storm fires even with memory apparently free")
    func firesOnSwapStorm() {
        var monitor = pressure(swapDeltaPages: 80_000)
        #expect(monitor.evaluate(VMSample(availableBytes: 8 * gigabyte,
                                          pageoutPages: 1_000)) == nil)
        let reason = monitor.evaluate(
            VMSample(availableBytes: 8 * gigabyte, pageoutPages: 200_000))
        #expect(reason?.contains("swap") == true)
    }

    /// `pageouts` is cumulative since boot, so the first reading establishes a baseline
    /// and cannot itself be a delta — otherwise every render on a machine that has ever
    /// swapped would be killed on its first poll.
    @Test("the first reading is a baseline, not a delta")
    func firstPageoutReadingIsABaseline() {
        var monitor = pressure(swapDeltaPages: 80_000)
        #expect(monitor.evaluate(VMSample(availableBytes: 8 * gigabyte,
                                          pageoutPages: 50_000_000)) == nil)
    }

    @Test("a steady trickle of paging is not a storm")
    func toleratesSteadyPaging() {
        var monitor = pressure(swapDeltaPages: 80_000)
        for step in 0..<20 {
            let sample = VMSample(availableBytes: 8 * gigabyte,
                                  pageoutPages: UInt64(step) * 1_000)
            #expect(monitor.evaluate(sample) == nil)
        }
    }
}

@Suite("MemoryWatchdog")
struct MemoryWatchdogTests {
    /// The runner starts the watchdog from a detached task once the child's pgid is
    /// known, so a child that dies almost immediately can get its `stop()` in first. A
    /// loop started after that would keep polling with a pgid the kernel may reuse — and
    /// then SIGKILL somebody else's process group.
    @Test("a start that arrives after stop is ignored")
    func lateStartIsANoOp() async {
        let fired = Fired()
        let starved = VMSample(availableBytes: 0, pageoutPages: 0)
        let watchdog = MemoryWatchdog(floorMB: 2000, interval: .milliseconds(1),
                                      sampler: { starved })
        await watchdog.stop()
        await watchdog.start { _ in fired.set() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fired.value == false)
    }

    @Test("a normal start does fire")
    func normalStartFires() async {
        let fired = Fired()
        let starved = VMSample(availableBytes: 0, pageoutPages: 0)
        let watchdog = MemoryWatchdog(floorMB: 2000, interval: .milliseconds(1),
                                      sampler: { starved })
        await watchdog.start { _ in fired.set() }
        try? await Task.sleep(for: .milliseconds(50))
        await watchdog.stop()
        #expect(fired.value == true)
    }
}

private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

@Suite("MachMemory")
struct MachMemoryTests {
    /// Not a test of the value — only that the Mach plumbing returns something sane.
    /// The formula itself (`free - speculative + inactive + purgeable`) is deliberately
    /// pessimistic and cannot be asserted against a live machine.
    @Test("sampling the live machine returns a plausible reading")
    func samplesTheMachine() throws {
        let sample = try #require(MachMemory.sample())
        #expect(sample.availableBytes > 0)
        #expect(sample.availableBytes < 2048 * 1024 * 1024 * 1024)
    }
}
