import Foundation
import SkillcaskCore

/// The app's own version, `CFBundleShortVersionString` (`bundle.sh` writes the Cargo version, so it is the bundled
/// CLI's too). nil turns the update check off: `swift run` has no `.app` and no version, and a version that is not
/// strict (`Version.init?(strict:)`) is not one a release has. Read once at launch and injected; never inside a
/// test, where `Bundle.main` is the test runner's.
public enum AppVersion {
    /// The version of a bundle at `bundlePath` with `info` as its Info.plist; nil unless the path is an `.app`.
    public static func read(info: [String: Any]?, bundlePath: String) -> Version? {
        guard bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/") else { return nil }
        return (info?["CFBundleShortVersionString"] as? String).flatMap(Version.init(strict:))
    }

    /// The running app's version.
    public static func main() -> Version? {
        read(info: Bundle.main.infoDictionary, bundlePath: Bundle.main.bundlePath)
    }
}

/// What the update sheet builds locally (D51): never a URL or a command from the response.
public enum UpdateLinks {
    /// The Homebrew update for the cask and the formula it depends on.
    public static let homebrewCommand = "brew update && brew upgrade skillcask skillcask-app"

    /// `https://github.com/GetResponse/skillcask/releases/tag/v<version>`; nil for a version that is not strict.
    public static func releasePage(for version: Version) -> URL? {
        guard version.isStrict else { return nil }
        return URL(string: "https://github.com/GetResponse/skillcask/releases/tag/v\(version)")
    }

    /// `Skillcask-<version>-macos-universal.zip`, the release asset the direct-download steps name.
    public static func zipName(for version: Version) -> String? {
        version.isStrict ? "Skillcask-\(version)-macos-universal.zip" : nil
    }
}
