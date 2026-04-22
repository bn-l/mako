import Foundation

/// Declared output format for the `say` subcommand. `auto` defers to the
/// runtime ffmpeg probe.
public enum OutputFormat: String, Sendable, CaseIterable {
    case auto, wav, m4a
}

public struct OutputPlan: Equatable, Sendable {
    public let url: URL
    public let wantM4A: Bool

    public init(url: URL, wantM4A: Bool) {
        self.url = url
        self.wantM4A = wantM4A
    }
}

public enum OutputResolverError: Error, Equatable, CustomStringConvertible {
    case extensionFormatMismatch(extension: String, format: OutputFormat)

    public var description: String {
        switch self {
        case let .extensionFormatMismatch(ext, format):
            return "--format \(format.rawValue) conflicts with output extension .\(ext); remove one or make them match"
        }
    }
}

/// Pure output-path resolution for `mac-tts say`. Extracted so the rules —
/// `-o` extension beats `--format`, explicit conflict is a hard error,
/// `--format auto` falls through to the ffmpeg probe — are testable without
/// spawning the CLI.
public enum OutputResolver {
    public static func resolve(
        format: OutputFormat,
        requested: String?,
        ffmpegAvailable: Bool
    ) throws -> OutputPlan {
        if let requested {
            let url = URL(fileURLWithPath: requested)
            let ext = url.pathExtension.lowercased()
            let extFormat: OutputFormat? = (ext == "m4a") ? .m4a : (ext == "wav") ? .wav : nil
            if let extFormat {
                if format != .auto && format != extFormat {
                    throw OutputResolverError.extensionFormatMismatch(extension: ext, format: format)
                }
                return OutputPlan(url: url, wantM4A: extFormat == .m4a)
            }
            let wantM4A: Bool
            switch format {
            case .auto: wantM4A = ffmpegAvailable
            case .wav: wantM4A = false
            case .m4a: wantM4A = true
            }
            return OutputPlan(url: url, wantM4A: wantM4A)
        }
        let wantM4A: Bool
        switch format {
        case .auto: wantM4A = ffmpegAvailable
        case .wav: wantM4A = false
        case .m4a: wantM4A = true
        }
        let name = wantM4A ? "out.m4a" : "out.wav"
        return OutputPlan(url: URL(fileURLWithPath: name), wantM4A: wantM4A)
    }
}

/// Resolves where the input text comes from. `-`/nil means stdin; any other
/// positional argument is taken verbatim. Pure so the selection rule is
/// testable without feeding real stdin.
public enum InputSource: Equatable, Sendable {
    case literal(String)
    case stdin

    public static func decide(argument: String?) -> InputSource {
        guard let argument, argument != "-" else { return .stdin }
        return .literal(argument)
    }
}
