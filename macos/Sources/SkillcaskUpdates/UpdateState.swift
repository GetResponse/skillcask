import Foundation
import SkillcaskCore

/// Whether the user allowed the daily check (D51). Asked once in the sidebar; Settings › Updates switches it.
public enum UpdateConsent: String, Hashable, Sendable, CaseIterable {
    /// Never answered: no automatic check; the sidebar may ask.
    case undecided
    /// `Check Daily`: check on launch when due, then every 24 hours.
    case granted
    /// `Not Now`, or the switch turned off: only "Check for Updates…" asks.
    case declined
}

/// Everything the update check remembers between launches (`UpdateDefaults`). Values, no clock: every change that
/// depends on time takes `now`.
public struct UpdateState: Hashable, Sendable {
    /// How long × hides the card for the version it showed.
    public static let hideInterval: TimeInterval = 7 * 24 * 60 * 60
    /// How long `Remind Me Tomorrow` hides the card.
    public static let remindInterval: TimeInterval = 24 * 60 * 60

    public var consent: UpdateConsent
    /// The last check that answered, automatic or manual; failures leave it.
    public var lastCheckAt: Date?
    /// The newest version a check reported, kept across launches so the card survives a relaunch and an offline
    /// check.
    public var latestSeen: Version?
    /// `Skip This Version`: that version never shows a card; a newer one does.
    public var skippedVersion: Version?
    /// × on the card: hidden until `hiddenUntil` for `hiddenForVersion` and older.
    public var hiddenUntil: Date?
    public var hiddenForVersion: Version?
    /// `Remind Me Tomorrow`: no card before this, whatever the version.
    public var remindAfter: Date?
    /// The Homebrew command was copied: "Waiting for the update" until the next launch.
    public var awaitingRelaunch: Bool
    /// The last check's `managed` (D61): the organisation updates the app, so the sheet shows this, not steps.
    public var managed: String?

    public init(
        consent: UpdateConsent = .undecided, lastCheckAt: Date? = nil, latestSeen: Version? = nil,
        skippedVersion: Version? = nil, hiddenUntil: Date? = nil, hiddenForVersion: Version? = nil,
        remindAfter: Date? = nil, awaitingRelaunch: Bool = false, managed: String? = nil
    ) {
        self.consent = consent
        self.lastCheckAt = lastCheckAt
        self.latestSeen = latestSeen
        self.skippedVersion = skippedVersion
        self.hiddenUntil = hiddenUntil
        self.hiddenForVersion = hiddenForVersion
        self.remindAfter = remindAfter
        self.awaitingRelaunch = awaitingRelaunch
        self.managed = managed
    }

    /// A check's outcome, automatic or manual. A document sets `lastCheckAt` and, when its `latest` is a strict
    /// version, `latestSeen` (a cask the CLI could not read keeps the last known one), and `managed` when the
    /// document has the key (a CLI before 0.12.1 never prints it, which says nothing about the machine). An
    /// unsupported CLI and every failure (offline, timed out) change nothing, so the card stays as it was and
    /// nothing is shown.
    public mutating func record(_ result: Result<SelfCheckOutcome, CLIError>, at now: Date) {
        guard case .success(.checked(let document)) = result else { return }
        lastCheckAt = now
        if let managed = document.managed {
            self.managed = managed
        }
        if let latest = document.latestVersion {
            latestSeen = latest
        }
    }

    /// `Skip This Version`.
    public mutating func skip(_ version: Version) {
        skippedVersion = version
    }

    /// Settings › Updates `Reset`.
    public mutating func resetSkipped() {
        skippedVersion = nil
    }

    /// × on the card showing `version`.
    public mutating func hide(_ version: Version, at now: Date) {
        hiddenForVersion = version
        hiddenUntil = now.addingTimeInterval(Self.hideInterval)
    }

    /// `Remind Me Tomorrow`.
    public mutating func remindTomorrow(at now: Date) {
        remindAfter = now.addingTimeInterval(Self.remindInterval)
    }

    /// `Copy Command` / `Copy and Open Terminal` for a Homebrew install.
    public mutating func copiedCommand() {
        awaitingRelaunch = true
    }

    /// The launch hook: a new process means Homebrew finished (or the user gave up), so the waiting card goes.
    public mutating func launched() {
        awaitingRelaunch = false
    }
}
