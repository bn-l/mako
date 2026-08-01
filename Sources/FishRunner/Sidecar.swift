import Foundation
import Darwin

struct SidecarResult: Sendable {
    /// `128 + signal` when the child was killed, matching shell convention.
    let exitCode: Int32
    let signaled: Bool
    let standardOutput: Data
    let standardError: Data
}

/// The process group of the render currently in flight, or 0.
///
/// A plain global rather than an actor because the signal handler reads it, and only
/// `kill`, `signal` and `raise` are safe to call from one. Reads and writes of a
/// word-sized value are atomic on Apple silicon, and there is never more than one render
/// in flight.
private nonisolated(unsafe) var activeChildPGID: pid_t = 0

/// Ctrl+C would otherwise not reach the child at all.
///
/// Putting the sidecar in its own process group is what makes it killable as a unit —
/// `uv` forks a `python` that holds all 6.8 GB, so killing `uv` alone leaves the weights
/// resident. But that same move takes the child out of the terminal's foreground process
/// group, so the tty stops delivering SIGINT to it. Without this handler, Ctrl+C returns
/// the shell prompt and leaves a multi-gigabyte orphan rendering into a file nobody will
/// read — exactly the state the watchdog exists to prevent.
private func forwardTerminationSignal(_ number: Int32) {
    if activeChildPGID > 0 { kill(-activeChildPGID, SIGKILL) }
    signal(number, SIG_DFL)
    raise(number)
}

enum Sidecar {
    /// Resolves an executable the way a shell would, plus the two Homebrew prefixes —
    /// a GUI-launched process inherits a minimal PATH that has neither.
    static func locate(_ tool: String) -> String? {
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var directories = searchPath.split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(tool).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Spawns `executable`, feeds it `input` on stdin, and runs it to completion.
    ///
    /// Blocking by design — call it off the cooperative pool. `onSpawn` receives the
    /// child's process group id (equal to its pid) as soon as it exists, which is when
    /// the memory watchdog can start.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        input: Data,
        stderrSink: (@Sendable (Data) -> Void)? = nil,
        onSpawn: (pid_t) -> Void
    ) throws -> SidecarResult {
        // A child that dies mid-render turns the remaining stdin writes into SIGPIPE,
        // which would take mako down instead of surfacing the child's own error.
        signal(SIGPIPE, SIG_IGN)

        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        var errorFromChild: [Int32] = [-1, -1]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0, pipe(&errorFromChild) == 0 else {
            throw RunnerSpawnError.pipeFailed(errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorFromChild[1], STDERR_FILENO)
        for descriptor in [toChild[0], toChild[1], fromChild[0], fromChild[1],
                           errorFromChild[0], errorFromChild[1]] {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETPGROUP with a group of 0 means "the child leads its own group", so a later
        // kill(-pgid) reaches uv and the python it forks. SETSIGMASK hands the child an
        // empty mask, so the block we take out below cannot leak into it.
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        // Block the terminating signals across the spawn so a Ctrl+C landing between
        // "child exists" and "handler knows its pgid" cannot orphan it.
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGINT)
        sigaddset(&blocked, SIGTERM)
        var previousMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previousMask)
        let previousInterrupt = signal(SIGINT, forwardTerminationSignal)
        let previousTerminate = signal(SIGTERM, forwardTerminationSignal)

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        if status == 0 { activeChildPGID = pid }
        pthread_sigmask(SIG_SETMASK, &previousMask, nil)

        defer {
            activeChildPGID = 0
            signal(SIGINT, previousInterrupt)
            signal(SIGTERM, previousTerminate)
        }

        close(toChild[0])
        close(fromChild[1])
        close(errorFromChild[1])
        guard status == 0 else {
            close(toChild[1]); close(fromChild[0]); close(errorFromChild[0])
            throw RunnerSpawnError.spawnFailed(status)
        }
        onSpawn(pid)

        // stdin, stdout and stderr all move concurrently. The sidecar logs a progress
        // line per batch, and a long render would fill the 64 KB pipe buffer and deadlock
        // if stderr were only read after waiting.
        let collected = Collected()
        let group = DispatchGroup()
        let stdinWrite = toChild[1], stdoutRead = fromChild[0], stderrRead = errorFromChild[0]
        DispatchQueue.global().async(group: group) { write(fd: stdinWrite, input) }
        DispatchQueue.global().async(group: group) {
            collected.setOutput(readToEnd(fd: stdoutRead))
        }
        DispatchQueue.global().async(group: group) {
            collected.setError(readToEnd(fd: stderrRead, sink: stderrSink))
        }

        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) < 0 && errno == EINTR {}
        group.wait()

        let signaled = (waitStatus & 0x7f) != 0 && (waitStatus & 0x7f) != 0x7f
        let terminatingSignal = waitStatus & 0x7f
        return SidecarResult(
            exitCode: signaled ? 128 + terminatingSignal : (waitStatus >> 8) & 0xff,
            signaled: signaled,
            standardOutput: collected.output,
            standardError: collected.error)
    }
}

enum RunnerSpawnError: Error, CustomStringConvertible {
    case pipeFailed(Int32)
    case spawnFailed(Int32)

    var description: String {
        switch self {
        case .pipeFailed(let code): return "could not create a pipe (errno \(code))"
        case .spawnFailed(let code): return "could not start the sidecar (errno \(code))"
        }
    }
}

/// Somewhere for the two reader queues to put their results.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOutput = Data()
    private var storedError = Data()

    var output: Data { lock.withLock { storedOutput } }
    var error: Data { lock.withLock { storedError } }

    func setOutput(_ data: Data) { lock.withLock { storedOutput = data } }
    func setError(_ data: Data) { lock.withLock { storedError = data } }
}

/// `sink` sees each chunk as it arrives, which is what makes a fourteen-minute render
/// show its per-batch progress instead of sitting silent. The full text is still
/// accumulated, because that is what the error path reports.
private func readToEnd(fd: Int32, sink: (@Sendable (Data) -> Void)? = nil) -> Data {
    defer { close(fd) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            let chunk = Data(buffer[0..<count])
            data.append(chunk)
            sink?(chunk)
        } else if count == 0 || errno != EINTR {
            return data
        }
    }
}

private func write(fd: Int32, _ data: Data) {
    defer { close(fd) }
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            if count > 0 {
                offset += count
            } else if errno != EINTR {
                return  // EPIPE: the child is gone, and its own error is the real one
            }
        }
    }
}
