import Foundation

/// Credits shown by the About page. The bundle carries the release version and an
/// automatically assigned build number; unbundled runs are labeled development.
enum AboutInfo {
    static let name = "Redlight"
    static let author = "Andrew Fitzgerald"
    static let repositoryURL = URL(string: "https://github.com/andrewfitz/redlight")!
    static let repositoryDisplay = "github.com/andrewfitz/redlight"

    static func version(
        shortVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    ) -> String {
        let short = normalized(shortVersion) ?? "development"
        guard let build = normalized(build), build != short else { return short }
        return "\(short) (\(build))"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
