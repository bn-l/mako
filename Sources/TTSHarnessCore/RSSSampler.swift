import Foundation

public struct RSSMeasurement: Sendable {
    public let peakBytes: UInt64
    public let avgBytes: UInt64
    public let sampleCount: Int
}

public actor RSSSampler {
    private var samples: [UInt64] = []
    private var peak: UInt64 = 0
    private var task: Task<Void, Never>?
    private let interval: Duration

    public init(interval: Duration = .milliseconds(500)) {
        self.interval = interval
    }

    public func start() {
        samples.removeAll()
        peak = 0
        let interval = self.interval
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let rss = sampleTreeRSSBytes()
                await self.record(rss)
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() -> RSSMeasurement {
        task?.cancel()
        task = nil
        let avg = samples.isEmpty ? 0 : samples.reduce(UInt64(0), +) / UInt64(samples.count)
        return RSSMeasurement(peakBytes: peak, avgBytes: avg, sampleCount: samples.count)
    }

    private func record(_ rss: UInt64) {
        samples.append(rss)
        if rss > peak { peak = rss }
    }
}

private func sampleTreeRSSBytes() -> UInt64 {
    let myPid = ProcessInfo.processInfo.processIdentifier
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-A", "-o", "pid=,ppid=,rss="]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do { try proc.run() } catch { return 0 }
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""

    var rssByPid: [Int32: UInt64] = [:]
    var childrenOf: [Int32: [Int32]] = [:]
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 3,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]),
              let rssKb = UInt64(fields[2])
        else { continue }
        rssByPid[pid] = rssKb * 1024
        childrenOf[ppid, default: []].append(pid)
    }

    var total: UInt64 = 0
    var stack: [Int32] = [myPid]
    var seen: Set<Int32> = []
    while let pid = stack.popLast() {
        guard seen.insert(pid).inserted else { continue }
        total += rssByPid[pid] ?? 0
        stack.append(contentsOf: childrenOf[pid] ?? [])
    }
    return total
}
