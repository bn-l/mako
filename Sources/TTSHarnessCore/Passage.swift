import Foundation

public enum Passage {
    /// Built-in passages shipped in `Resources/`. Reference them by name (e.g. `"gulliver"`).
    public static let bundledNames: [String] = [
        "gulliver", "maya", "trouble", "quiet-house", "death-blow", "micro-corpus", "brutal", "foot-massage", "reflexology-class",
    ]
    public static let defaultName = "gulliver"

    /// Load a passage. If `source` is `nil`, loads the default bundled passage.
    /// If `source` matches a bundled passage name, loads that. Otherwise treats
    /// it as a filesystem path.
    /// Load a bundled fixture `.txt` resource by stem name. Exposes
    /// `Bundle.module` to callers outside TTSHarnessCore (tests, chiefly)
    /// without forcing `Passage.bundledNames` to grow to cover fixtures
    /// that aren't prose passages (e.g. `homographs.txt`).
    public static func loadFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            throw RunnerError.missingResource("bundled fixture \"\(name).txt\" not found")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func load(_ source: String? = nil) throws -> String {
        let name = source ?? defaultName
        if bundledNames.contains(name), let url = Bundle.module.url(forResource: name, withExtension: "txt") {
            return try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fileURL = URL(fileURLWithPath: name)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RunnerError.missingResource(
                "passage \"\(name)\" not found as bundled name (\(bundledNames.joined(separator: ", "))) or file path"
            )
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
