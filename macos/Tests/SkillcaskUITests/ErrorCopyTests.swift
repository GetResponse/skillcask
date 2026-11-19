import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// Every `CLIError` reads as a sentence with no exit code, the hint passes through unless the table
/// rewords it, the fixture banners say what the boards say, and the toast keeps its words and its 4 s.
@Suite struct ErrorCopyTests {
    /// One value per `CLIError` case.
    static let everyError: [CLIError] = [
        .binaryMissing(searched: ["/opt/homebrew/bin", "/usr/local/bin"]),
        .binaryIsApp(path: "/Applications/Skillcask.app/Contents/MacOS/Skillcask"),
        .unreadableVersion(output: "zsh: command not found"),
        .tooOld(found: Version(0, 7, 2), needs: Version(0, 9, 0)),
        .unsupported(feature: "addRename"),
        .invalidInvocation("empty package list"),
        .launchFailed("Permission denied"),
        .failed(code: .problem, message: "skills.toml not found", hint: "run skillcask init", stderr: "error: x"),
        .failed(code: .signIn, message: "api.github.com: denied", hint: nil, stderr: ""),
        .failed(code: .network, message: "packagist.org: timed out", hint: nil, stderr: ""),
        .failed(code: .integrity, message: "acme/review-pr: hash mismatch", hint: nil, stderr: ""),
        .failed(code: .file, message: "skills.lock: permission denied", hint: nil, stderr: ""),
        .failed(code: .other(101), message: "panicked at src/main.rs", hint: nil, stderr: "thread main panicked"),
        .cancelled,
        .killed(signal: 9),
        .noDocument,
        .decode("missing key ok", raw: Data("{}".utf8)),
        .outputTooLarge(limit: 16_777_216),
    ]

    // MARK: - Every case

    @Test func everyCaseReadsAsOneSentenceWithoutCodes() {
        for error in Self.everyError {
            let message = ErrorCopy.message(for: error)
            #expect(!message.title.isEmpty, "\(error)")
            #expect(message.title.hasSuffix("."), "\(error): \(message.title)")
            #expect(!message.title.localizedCaseInsensitiveContains("exit"), "\(error): \(message.title)")
            #expect(message.title.range(of: #"\b\d+\b"#, options: .regularExpression) == nil, "\(message.title)")
            for sentence in [message.reason, message.action].compactMap({ $0 }) {
                #expect(!sentence.localizedCaseInsensitiveContains("exit"), "\(error): \(sentence)")
            }
        }
    }

    @Test func integrityFlagMarksExitFourOnly() {
        for error in Self.everyError {
            let message = ErrorCopy.message(for: error)
            if case .failed(.integrity, _, _, _) = error {
                #expect(message.isIntegrity)
                #expect(message.reason == ErrorCopy.nothingWasChanged)
                #expect(message.remedy == nil)
            } else {
                #expect(!message.isIntegrity, "\(error)")
            }
        }
    }

    @Test func remediesFollowTheExitCode() {
        #expect(
            ErrorCopy.message(for: .failed(code: .signIn, message: "denied", hint: nil, stderr: "")).remedy == .signIn)
        #expect(
            ErrorCopy.message(for: .failed(code: .network, message: "down", hint: nil, stderr: "")).remedy == .retry)
        #expect(ErrorCopy.message(for: .failed(code: .problem, message: "bad", hint: nil, stderr: "")).remedy == nil)
        #expect(ErrorCopy.message(for: .failed(code: .file, message: "gone", hint: nil, stderr: "")).remedy == nil)
        #expect(ErrorCopy.message(for: .cancelled).severity == .neutral)
        #expect(ErrorCopy.message(for: .cancelled).title == "Cancelled.")
    }

    @Test func rawTextLandsInDetailsOnly() {
        let failed = ErrorCopy.message(
            for: .failed(code: .other(101), message: "panicked", hint: nil, stderr: "thread main panicked\nat x"))
        #expect(failed.details == "thread main panicked\nat x")
        #expect(ErrorCopy.message(for: .failed(code: .problem, message: "x", hint: nil, stderr: "  ")).details == nil)
        let decode = ErrorCopy.message(for: .decode("missing key ok", raw: Data("{\"a\":1}".utf8)))
        #expect(decode.details == "missing key ok\n\n{\"a\":1}")
        let tooOld = ErrorCopy.message(for: .tooOld(found: Version(0, 7, 2), needs: Version(0, 9, 0)))
        #expect(tooOld.details == "Found 0.7.2\nNeeded 0.9.0 or newer")
        #expect(tooOld.title == "Skillcask needs a newer command-line tool.")
        let missing = ErrorCopy.message(for: .binaryMissing(searched: ["/a", "/b"]))
        #expect(missing.details == "/a\n/b")
        #expect(missing.title == "Skillcask needs its command-line tool.")
        #expect(ErrorCopy.message(for: .killed(signal: 9)).details == "Signal 9")
    }

    // MARK: - Hints

    @Test func hintPassesThroughUnlessTheTableRewordsIt() {
        #expect(ErrorCopy.action(forHint: "run skillcask install") == "Sync this project.")
        #expect(ErrorCopy.action(forHint: "run skillcask init") == "Set up this folder.")
        #expect(
            ErrorCopy.action(forHint: "review the lines above; if they are fine, lift deny-patterns")
                == "Review the lines above; if they are fine, lift deny-patterns.")
        #expect(
            ErrorCopy.action(forHint: "Check your connection and try again.") == "Check your connection and try again.")
        #expect(ErrorCopy.action(forHint: nil) == nil)
        #expect(ErrorCopy.action(forHint: "   ") == nil)
        let unknown = ErrorCopy.message(
            for: .failed(code: .problem, message: "x", hint: "ask the maintainer of config.toml", stderr: ""))
        #expect(unknown.action == "Ask the maintainer of config.toml.")
    }

    @Test func fallbackActionsFillAMissingHint() {
        #expect(
            ErrorCopy.message(for: .failed(code: .signIn, message: "denied", hint: nil, stderr: "")).action
                == ErrorCopy.signInAction)
        #expect(
            ErrorCopy.message(for: .failed(code: .network, message: "down", hint: nil, stderr: "")).action
                == ErrorCopy.networkAction)
        #expect(
            ErrorCopy.message(for: .failed(code: .integrity, message: "mismatch", hint: nil, stderr: "")).action
                == ErrorCopy.integrityAction)
        #expect(ErrorCopy.message(for: .failed(code: .problem, message: "bad", hint: nil, stderr: "")).action == nil)
    }

    @Test func sentencesKeepNamesAndGainAFullStop() {
        #expect(ErrorCopy.sentence("the source needs you to sign in") == "The source needs you to sign in.")
        #expect(ErrorCopy.sentence("skills.toml not found") == "skills.toml not found.")
        #expect(ErrorCopy.sentence("acme/review-pr: hash mismatch") == "acme/review-pr: hash mismatch.")
        #expect(ErrorCopy.sentence("Done!") == "Done!")
        #expect(ErrorCopy.sentence("  ") == "Something went wrong.")
        #expect(ErrorCopy.sentence("Resolving…") == "Resolving…")
    }

    // MARK: - Boards

    @Test func fixtureBannersSayWhatTheBoardsSay() {
        let signIn = ErrorCopy.message(for: DesignFixtures.signInBanner.error, title: DesignFixtures.signInBanner.title)
        #expect(signIn.title == "Couldn’t sync sql-review.")
        #expect(signIn.reason == "The source git.acme.example needs you to sign in.")
        #expect(signIn.action == "Add a token in Settings › Updates, then Sync again. The other 13 skills were synced.")
        #expect(signIn.remedy == .signIn && signIn.severity == .error && !signIn.isIntegrity)

        let integrity = ErrorCopy.message(
            for: DesignFixtures.integrityBanner.error, title: DesignFixtures.integrityBanner.title)
        #expect(integrity.title == "Integrity failure while updating review-pr.")
        #expect(integrity.reason == "The downloaded content did not match the lock. Nothing was changed.")
        #expect(integrity.isIntegrity && integrity.remedy == nil)
        #expect(
            FailureBanner.bodyText(integrity)
                == "The downloaded content did not match the lock. Nothing was changed. "
                + "This can mean the source was tampered with. Tell whoever maintains acme/review-pr before trying again."
        )

        let notFound = ErrorCopy.message(for: DesignFixtures.notFoundFailure.error)
        #expect(notFound.title == "No package with that name in packagist or acme.")
        #expect(notFound.action == "Check the spelling, or search for “jira triage” instead.")
        #expect(notFound.severity == .error)

        let policy = ErrorCopy.message(for: DesignFixtures.policyFailure.error)
        #expect(policy.severity == .warning)
        #expect(policy.title.hasPrefix("Allowed sources are packagist, acme"))

        let unreachable = ErrorCopy.message(for: DesignFixtures.unreachableFailure.error)
        #expect(unreachable.title == "Couldn’t reach packagist.")
        #expect(unreachable.action == "Check your connection and try again; acme answered.")
        #expect(unreachable.remedy == .retry)
        #expect(FailureBanner.showsRetry(unreachable) && !FailureBanner.showsRetry(integrity))
        #expect(FailureBanner.showsSignIn(signIn) && !FailureBanner.showsSignIn(unreachable))
    }

    @Test func nameClashIsTheBoardsWarning() {
        let clash = DesignFixtures.nameClash
        let message = ErrorCopy.nameClash(
            existing: clash.existing, existingPackage: clash.existingPackage, newPackage: clash.newPackage)
        #expect(message.title == "A skill named pdf already exists in this project.")
        #expect(message.reason == "It comes from anthropics/skills.")
        #expect(message.action == "Install the new one from kolya/pdf-tools under another name so both can be linked.")
        #expect(message.severity == .warning && !message.isIntegrity && message.remedy == nil)
    }

    @Test func bannerSymbolsFollowTheKind() {
        #expect(FailureBanner.symbol(for: UserMessage(title: "x", isIntegrity: true)) == "xmark.shield")
        #expect(FailureBanner.symbol(for: UserMessage(title: "x")) == "xmark.circle")
        #expect(FailureBanner.symbol(for: UserMessage(title: "x", severity: .warning)) == "exclamationmark.triangle")
        #expect(FailureBanner.symbol(for: UserMessage(title: "x", severity: .neutral)) == "info.circle")
    }

    @Test func networkFailuresDrawTheCrossedWifi() {
        let unreachable = ErrorCopy.message(for: DesignFixtures.unreachableFailure.error)
        #expect(FailureBanner.symbol(for: unreachable) == "wifi.slash")
        let integrity = ErrorCopy.message(for: .failed(code: .integrity, message: "mismatch", hint: nil, stderr: ""))
        #expect(FailureBanner.symbol(for: integrity) == "xmark.shield")
    }

    @Test func retryAloneLaysOutInlineEverythingElseStacks() {
        let unreachable = ErrorCopy.message(for: DesignFixtures.unreachableFailure.error)
        #expect(FailureBanner.layout(for: unreachable, hasRetry: true, hasDetails: false) == .inline)
        #expect(FailureBanner.layout(for: unreachable, hasRetry: true, hasDetails: true) == .stacked)
        #expect(FailureBanner.layout(for: unreachable, hasRetry: false, hasDetails: false) == .stacked)
        let signIn = ErrorCopy.message(for: DesignFixtures.signInBanner.error)
        #expect(FailureBanner.layout(for: signIn, hasRetry: true, hasDetails: false) == .stacked)
        let integrity = ErrorCopy.message(for: DesignFixtures.integrityBanner.error)
        #expect(FailureBanner.layout(for: integrity, hasRetry: true, hasDetails: false) == .stacked)
    }

    @Test func policyRefusalNamesItsSourcesInMono() {
        let policy = ErrorCopy.message(for: DesignFixtures.policyFailure.error)
        #expect(policy.monoFragment == "packagist, acme")
        #expect(ErrorCopy.message(for: DesignFixtures.notFoundFailure.error).monoFragment == nil)
        #expect(ErrorCopy.policyMonoFragment("GitHub is not allowed here") == nil)
    }

    @Test func patternHintsKeepTheNamesAndDropTheCommand() {
        let doctor = "skillcask --global doctor --fix repairs links and ~/.config/skillcask/.gitignore"
        #expect(ErrorCopy.action(forHint: doctor) == "Repair fixes the links and ~/.config/skillcask/.gitignore.")
        let conflict =
            "resolve skills.toml first, keep either side of skills.lock (e.g. git checkout --theirs skills.lock), "
            + "then run skillcask install; it locks what that side lacks"
        #expect(
            ErrorCopy.action(forHint: conflict)
                == "Resolve skills.toml first and keep either side of skills.lock, then Sync; it locks what that side lacks."
        )
        for hint in [
            doctor, conflict, "run skillcask install", "skillcask doctor --fix repairs links and the gitignore block",
        ] {
            let action = ErrorCopy.action(forHint: hint) ?? ""
            #expect(!action.contains("skillcask "), "\(action)")
            #expect(!action.contains("--"), "\(action)")
        }
        #expect(ErrorCopy.rewordedByPattern("something else entirely") == nil)
    }

    // MARK: - Toast

    @Test func toastWordsMatchTheFixtures() {
        #expect(OutcomeCopy.updated("pdf", to: "1.4.0") == DesignFixtures.updatedToast.message)
        #expect(
            OutcomeCopy.added(["jira-syntax", "jira-communication"], version: "4.2.0")
                == DesignFixtures.addedToast.message)
        #expect(OutcomeCopy.added(["pdf"], version: "1.4.0") == "Added pdf (1.4.0)")
        #expect(OutcomeCopy.list(["a", "b", "c"]) == "a, b and c")
        #expect(OutcomeCopy.list([]) == "")
        #expect(OutcomeCopy.showDetails == DesignFixtures.updatedToast.action)
        #expect(OutcomeCopy.couldNot("sync sql-review") == DesignFixtures.signInBanner.title)
        #expect(OutcomeCopy.details == "Details" && OutcomeCopy.dismiss == "Dismiss" && OutcomeCopy.retry == "Retry")
        #expect(OutcomeCopy.openSettings == "Open Settings")
    }

    @Test func toastMessagesCompareByIdentityAndWords() {
        let id = UUID()
        let one = ToastMessage(id: id, text: "Updated pdf to 1.4.0", emphasis: "pdf")
        #expect(one == ToastMessage(id: id, text: "Updated pdf to 1.4.0", emphasis: "pdf"))
        #expect(one != ToastMessage(id: id, text: "Updated pdf to 1.4.0", emphasis: "pdf", showsDetails: false))
        #expect(one != ToastMessage(text: "Updated pdf to 1.4.0", emphasis: "pdf"), "a repeat is a new toast")
        #expect(one.showsDetails)
    }

    @Test func toastStaysFourSeconds() {
        #expect(Toast.duration == .seconds(4))
        #expect(Toast.inset == Spacing.m)
    }
}
