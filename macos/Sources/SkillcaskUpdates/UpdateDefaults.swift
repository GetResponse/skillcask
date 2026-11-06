import Foundation
import SkillcaskCore

/// `UpdateState` in `UserDefaults` under `appUpdates.*`; the suite is injected so tests never touch the real
/// defaults. Versions are stored as text and read back strictly, so a value edited by hand that is not a plain
/// version reads as unset.
public struct UpdateDefaults {
    /// The keys, in one place so tests, `smoke-app.sh`'s argument domain and a future migration can name them.
    public enum Key {
        /// `granted` / `declined`; absent is undecided.
        public static let consent = "appUpdates.consent"
        public static let lastCheckAt = "appUpdates.lastCheckAt"
        public static let latestSeen = "appUpdates.latestSeen"
        public static let skippedVersion = "appUpdates.skippedVersion"
        public static let hiddenUntil = "appUpdates.hiddenUntil"
        public static let hiddenForVersion = "appUpdates.hiddenForVersion"
        public static let remindAfter = "appUpdates.remindAfter"
        public static let awaitingRelaunch = "appUpdates.awaitingRelaunch"
        public static let managed = "appUpdates.managed"

        public static let all = [
            consent, lastCheckAt, latestSeen, skippedVersion, hiddenUntil, hiddenForVersion, remindAfter,
            awaitingRelaunch, managed,
        ]
    }

    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> UpdateState {
        UpdateState(
            consent: defaults.string(forKey: Key.consent).flatMap(UpdateConsent.init(rawValue:)) ?? .undecided,
            lastCheckAt: defaults.object(forKey: Key.lastCheckAt) as? Date,
            latestSeen: version(Key.latestSeen),
            skippedVersion: version(Key.skippedVersion),
            hiddenUntil: defaults.object(forKey: Key.hiddenUntil) as? Date,
            hiddenForVersion: version(Key.hiddenForVersion),
            remindAfter: defaults.object(forKey: Key.remindAfter) as? Date,
            awaitingRelaunch: defaults.bool(forKey: Key.awaitingRelaunch),
            managed: defaults.string(forKey: Key.managed))
    }

    /// Writes every key; a nil value (and `undecided`, `false`) removes it. For seeding a suite (tests, previews);
    /// the app writes through `save(_:changedFrom:)`.
    public func save(_ state: UpdateState) {
        save(state, keys: Key.all)
    }

    /// Writes only the keys whose values differ between `old` and `state`. `load()` reads the argument domain too
    /// (`-appUpdates.consent declined` from `smoke-app.sh`, or a one-off `--args`), so writing a key nobody changed
    /// would make a launch argument permanent.
    public func save(_ state: UpdateState, changedFrom old: UpdateState) {
        var keys: [String] = []
        if state.consent != old.consent { keys.append(Key.consent) }
        if state.lastCheckAt != old.lastCheckAt { keys.append(Key.lastCheckAt) }
        if state.latestSeen != old.latestSeen { keys.append(Key.latestSeen) }
        if state.skippedVersion != old.skippedVersion { keys.append(Key.skippedVersion) }
        if state.hiddenUntil != old.hiddenUntil { keys.append(Key.hiddenUntil) }
        if state.hiddenForVersion != old.hiddenForVersion { keys.append(Key.hiddenForVersion) }
        if state.remindAfter != old.remindAfter { keys.append(Key.remindAfter) }
        if state.awaitingRelaunch != old.awaitingRelaunch { keys.append(Key.awaitingRelaunch) }
        if state.managed != old.managed { keys.append(Key.managed) }
        save(state, keys: keys)
    }

    /// The launch hook: loads and clears `awaitingRelaunch` (`UpdateState.launched`), removing that one key when it
    /// was set and writing nothing otherwise; returns the state.
    @discardableResult
    public func launched() -> UpdateState {
        let old = load()
        var state = old
        state.launched()
        save(state, changedFrom: old)
        return state
    }

    private func save(_ state: UpdateState, keys: [String]) {
        for key in keys {
            switch key {
            case Key.consent: set(state.consent == .undecided ? nil : state.consent.rawValue, key)
            case Key.lastCheckAt: set(state.lastCheckAt, key)
            case Key.latestSeen: set(state.latestSeen?.description, key)
            case Key.skippedVersion: set(state.skippedVersion?.description, key)
            case Key.hiddenUntil: set(state.hiddenUntil, key)
            case Key.hiddenForVersion: set(state.hiddenForVersion?.description, key)
            case Key.remindAfter: set(state.remindAfter, key)
            case Key.awaitingRelaunch: set(state.awaitingRelaunch ? true : nil, key)
            case Key.managed: set(state.managed, key)
            default: break
            }
        }
    }

    private func version(_ key: String) -> Version? {
        defaults.string(forKey: key).flatMap(Version.init(strict:))
    }

    private func set(_ value: Any?, _ key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
