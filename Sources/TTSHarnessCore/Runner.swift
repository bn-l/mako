import Foundation

public protocol Runner: Sendable {
    var modelID: String { get }
    var sampleRate: Int { get }
    func synthesize(text: String, to outputURL: URL) async throws
}

public enum RunnerError: Error, CustomStringConvertible {
    case notImplemented(String)
    case missingResource(String)
    case subprocessFailed(exitCode: Int32, stderr: String)
    case decodeFailure(String)

    public var description: String {
        switch self {
        case .notImplemented(let msg): return "not implemented: \(msg)"
        case .missingResource(let msg): return "missing resource: \(msg)"
        case .subprocessFailed(let code, let err):
            return "subprocess exited \(code): \(err)"
        case .decodeFailure(let msg): return "decode failure: \(msg)"
        }
    }
}
