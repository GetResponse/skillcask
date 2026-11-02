import Foundation

/// `UserDefaults` that keeps every value in memory, so a test leaves no plist: `removePersistentDomain(forName:)`
/// empties a real suite, but cfprefsd writes an empty `~/Library/Preferences/<suite>.plist` seconds later.
/// `UpdateDefaults` reads through `object(forKey:)` (which `string(forKey:)` and `bool(forKey:)` call) and writes
/// through `set(_:forKey:)` and `removeObject(forKey:)`; `SplitViewFrames.repair` lists the keys through
/// `dictionaryRepresentation()`. Those four are what this overrides.
/// Keep in sync with `macos/Tests/SkillcaskUITests/MemoryDefaults.swift`.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    /// What was written.
    private(set) var values: [String: Any] = [:]
    /// Read before `values`, never written: stands in for the argument domain, which wins over the app's own.
    private let readOnly: [String: Any]

    /// Fails only if Foundation cannot open the process's own domain, which sits underneath unused: every accessor
    /// `UpdateDefaults` uses is overridden, so nothing reaches it.
    init?(readOnly: [String: Any] = [:]) {
        self.readOnly = readOnly
        super.init(suiteName: nil)
    }

    /// The double, or a test failure: the failable `init` only fails when Foundation cannot open the process's
    /// own domain, and a force unwrap trips swift-format's NeverForceUnwrap.
    static func make(readOnly: [String: Any] = [:]) -> MemoryDefaults {
        guard let defaults = MemoryDefaults(readOnly: readOnly) else {
            preconditionFailure("UserDefaults(suiteName: nil) failed")
        }
        return defaults
    }

    override func object(forKey defaultName: String) -> Any? {
        readOnly[defaultName] ?? values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }

    override func dictionaryRepresentation() -> [String: Any] {
        values.merging(readOnly) { _, argument in argument }
    }
}
