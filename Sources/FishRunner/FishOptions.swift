import Foundation
import TTSHarnessCore

/// Everything `mako say --hq` can vary about a fish render.
///
/// The tuning knobs default from `MAKO_FISH_*` environment variables, matching how the
/// Kokoro runner consumes `KOKORO_*`, so `mako dev say` can expose them as flags without
/// threading a dozen parameters through `performSay`. The handful of user-facing choices
/// (`--preset`, `--markers`, `--voice-ref`, `--seed`) are set directly by the caller.
public struct FishOptions: Sendable {
    public var preset: String
    public var keepMarkers: Bool
    /// Run mako's structural normalizer over the text first. Off by default — see
    /// `FishText` for why raw text is the validated path.
    public var normalize: Bool
    public var seed: Int
    /// Overrides the bundled production voice. Both must be given together, and the
    /// transcript must be exactly what the audio says — fish clones in context, so a
    /// mismatched transcript degrades the clone rather than failing loudly.
    public var referenceAudio: URL?
    public var referenceTranscript: URL?

    public var chunkLength: Int
    public var maxTokens: Int
    public var mlxCacheMB: Int
    public var gapMean: Double
    public var gapSD: Double
    public var fadeMS: Double
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    /// The sidecar's own guard, which sits above mako's so it normally trips first.
    public var oomFloorMB: Int
    /// Pass the sidecar's per-batch log through to mako's stderr. On by default: a long
    /// passage takes minutes, and silence for that long reads as a hang.
    public var progress: Bool

    public static let presets = ["default", "expressive", "warm", "hot"]

    /// Validated production settings. `chunkLength` is 400, not `gen_fish.py`'s 150.
    public init(
        preset: String = "hot",
        keepMarkers: Bool = false,
        normalize: Bool = false,
        seed: Int = 11,
        referenceAudio: URL? = nil,
        referenceTranscript: URL? = nil,
        chunkLength: Int = 400,
        maxTokens: Int = 900,
        mlxCacheMB: Int = 512,
        gapMean: Double = 0.6,
        gapSD: Double = 0.2,
        fadeMS: Double = 50,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        oomFloorMB: Int = 2200,
        progress: Bool = true
    ) {
        self.preset = preset
        self.keepMarkers = keepMarkers
        self.normalize = normalize
        self.seed = seed
        self.referenceAudio = referenceAudio
        self.referenceTranscript = referenceTranscript
        self.chunkLength = chunkLength
        self.maxTokens = maxTokens
        self.mlxCacheMB = mlxCacheMB
        self.gapMean = gapMean
        self.gapSD = gapSD
        self.fadeMS = fadeMS
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.oomFloorMB = oomFloorMB
        self.progress = progress
    }

    public static func fromEnvironment() -> FishOptions {
        let env = ProcessInfo.processInfo.environment
        func int(_ key: String, _ fallback: Int) -> Int {
            env["MAKO_FISH_" + key].flatMap(Int.init) ?? fallback
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            env["MAKO_FISH_" + key].flatMap(Double.init) ?? fallback
        }
        var options = FishOptions(
            preset: env["MAKO_FISH_PRESET"] ?? "hot",
            keepMarkers: env["MAKO_FISH_MARKERS"] != nil,
            normalize: env["MAKO_FISH_NORMALIZE"] != nil,
            seed: int("SEED", 11),
            chunkLength: int("CHUNK_LENGTH", 400),
            maxTokens: int("MAX_TOKENS", 900),
            mlxCacheMB: int("MLX_CACHE_MB", 512),
            gapMean: double("GAP_MEAN", 0.6),
            gapSD: double("GAP_SD", 0.2),
            fadeMS: double("FADE_MS", 50),
            temperature: env["MAKO_FISH_TEMPERATURE"].flatMap(Double.init),
            topP: env["MAKO_FISH_TOP_P"].flatMap(Double.init),
            topK: env["MAKO_FISH_TOP_K"].flatMap(Int.init),
            oomFloorMB: int("OOM_FLOOR_MB", 2200))
        options.referenceAudio = env["MAKO_FISH_REF_WAV"].map { URL(fileURLWithPath: $0) }
        options.referenceTranscript = env["MAKO_FISH_REF_TEXT"].map { URL(fileURLWithPath: $0) }
        return options
    }

    /// Sidecar arguments after `uv run --script <script>`. Split out so it can be
    /// asserted in a unit test without spawning anything.
    public func sidecarArguments(
        outputURL: URL, referenceAudio: URL, referenceTranscript: URL
    ) -> [String] {
        var args = [
            "--out", outputURL.path,
            "--ref-wav", referenceAudio.path,
            "--ref-text", referenceTranscript.path,
            "--preset", preset,
            "--chunk-length", String(chunkLength),
            "--max-tokens", String(maxTokens),
            "--mlx-cache-mb", String(mlxCacheMB),
            "--gap-mean", String(gapMean),
            "--gap-sd", String(gapSD),
            "--fade-ms", String(fadeMS),
            "--seed", String(seed),
            "--oom-floor-mb", String(oomFloorMB),
        ]
        if let temperature { args += ["--temperature", String(temperature)] }
        if let topP { args += ["--top-p", String(topP)] }
        if let topK { args += ["--top-k", String(topK)] }
        return args
    }
}
