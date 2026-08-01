import Foundation

/// Locations of the three files `mako say --hq` cannot run without.
///
/// They live in this target because `Bundle.module` is per-target: a runner target
/// cannot reach another target's bundle, so `FishRunner` asks for URLs instead of
/// looking them up itself.
///
/// The wav and the transcript are genuinely runtime dependencies, not build inputs.
/// Fish clones in context — `_prepare_reference_prompt` encodes the clip to VQ codes and
/// puts them in the system message — so there is no per-voice model to bake in, and the
/// transcript has to keep saying exactly what the audio says.
public enum FishResources {
    /// 22.05 kHz / 16-bit, 29.31 s. `load_audio(..., sample_rate=44100)` resamples it at
    /// load, exactly as every validated run did — do not "fix" the file by resampling it
    /// on disk, and do not assert 44.1 kHz anywhere.
    public static func referenceAudioURL() throws -> URL {
        try url(forResource: "gemini2-22", withExtension: "wav")
    }

    public static func referenceTranscriptURL() throws -> URL {
        try url(forResource: "gemini2-22", withExtension: "txt")
    }

    public static func sidecarScriptURL() throws -> URL {
        try url(forResource: "fish_say", withExtension: "py")
    }

    private static func url(forResource name: String, withExtension ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw RunnerError.missingResource(
                "\(name).\(ext) is missing from the mako resource bundle — reinstall mako")
        }
        return url
    }
}
