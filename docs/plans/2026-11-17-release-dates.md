# Release dates in `--json` Implementation Plan

> **For agentic workers:** steps use checkbox (`- [ ]`) syntax; tick them as you go. Run the checks of
> AGENTS.md after every task that touches `src/`, and `cd macos && ./test.sh` after every task that touches
> `macos/`. Line numbers are as of master `535367f`; re-check them before editing.

**Goal:** the macOS app's Versions tab shows when each version was released instead of "unknown"
(`macos/DESIGN.md` Q2 :185, Q6 :187-188). The CLI prints in its `--json` documents the release times it
already holds, under new keys only (D32: "Keys are only added"), and makes no request to find one.
Recorded as D67.

**Architecture:** release times live in `registry::Candidate.time` (src/registry.rs:34) and in the lock's
`released` (src/lock.rs:42), both `jiff::Timestamp`. Composer metadata dates every version in the request
`info`/`outdated` already make (registry.rs:219-225). GitHub and git tag lists carry no dates
(github.rs:154, git.rs:569); dating a tag costs a `/commits/{sha}` request (60/h anonymous) or a pack
fetch, so those stay `null` unless the candidate was already resolved. The app reads the new keys when
present and keeps "unknown" otherwise, so CLIs from 0.9.4 up keep working.

**Tech Stack:** Rust (jiff 0.2, serde_json `json!`), Swift 6.3 (SkillcaskCore documents, SkillcaskDomain
models, SkillcaskUI views).

---

## Decision D67 (docs/specs/2026-10-19-skillcask-v1.md, after D66 at :133)

| D67 | `--json` documents print the release times skillcask already holds, as RFC 3339 UTC strings rounded to the second, and `null` where none is in hand; no command makes a request to find one. `info` of a package gains `versions-released`, an object from entries of `versions` (same spelling, order not significant) to their time: every dated version for a Composer repository, only the shown or locked one for GitHub and git. `outdated` packages gain `locked-released`, `within-released`, `latest-released` and `eligible` (when a version of a Composer repository still in its cooldown becomes eligible, as `note` says, else `null`); `status` entries and `info` of an installed skill gain `released`, from skills.lock. | Composer metadata dates every version in the request already made; a GitHub tag costs one `/commits` request and a git tag one fetch, which the 60/h anonymous limit cannot carry for a version list. The time is the one the cooldown uses: Composer's `time`, GitHub's later of commit and release, git's commit date. `versions` stays a list of strings (D32). `outdated` gets no plain `released`: app 0.13.0 already decodes that key as the time of `latest` and would print it next to `within`. Named after the lock's `released` key. |

Also amend D32 (:100): `outdated` packages, `info` (package and skill documents) and `status` entries name
the new keys.

## Output shapes (the contract)

```json
// info --json -- acme/review          (Composer: every dated version)
{ "versions": ["1.6.1", "1.6.0", "1.5.0", "1.4.1"],
  "versions-released": { "1.4.1": "2026-10-27T18:19:10Z", "1.5.0": "2026-10-30T14:03:10Z",
                         "1.6.0": "2026-11-03T08:57:24Z", "1.6.1": "2026-11-05T11:48:50Z" }, "...": "..." }

// info --json -- github:owner/repo                     (only the shown/locked tag; {} for a ref/sha entry)
{ "versions": ["v1.3.2", "v1.3.1"], "versions-released": { "v1.3.2": "2026-10-29T10:27:41Z" } }

// info --json -- review                      (an installed skill)
{ "skill": "review", "kind": "package", "version": "1.6.1", "released": "2026-11-05T11:48:50Z", "...": "..." }

// outdated --json, one package; GitHub/git rows: within-released and latest-released null
{ "package": "netresearch/jira-skill", "locked": "v4.1.0", "within": "v4.3.3", "latest": "v5.0.0",
  "note": "v4.3.3 eligible 2026-11-13T15:07:45Z",
  "locked-released": "…", "within-released": "2026-11-10T15:07:45Z", "latest-released": "…",
  "eligible": "2026-11-13T15:07:45Z" }

// status --json, one entry; null for rows whose package is "-" or that have no lock entry
{ "package": "acme/review", "version": "1.6.1", "skill": "review",
  "state": "ok", "ok": true, "adopt": null, "via": null, "released": "2026-11-05T11:48:50Z" }
```

Rules: a version missing from `versions-released`, or `null`, means "not known"; map keys are spelled as in
`versions` (Packagist keeps its `v`) and only versions listed in `versions` appear; serde_json sorts object
keys, so readers must not rely on order. `within-released` dates `within` as `outdated` computes it: the
newest version matching the manifest constraint, cooldown not applied (same as `note`).

---

# Part A: CLI

### Task A1: one timestamp formatter

**Files:** Modify `src/commands.rs` (or a small shared module)

- [ ] **Step 1:** add `fn json_time(t: Option<Timestamp>) -> Value`: `t.round(jiff::Unit::Second)` as
  lock.rs:106 does, `Display` (`…Z`), `Value::Null` for `None`. No helper exists today; the same inline
  round is repeated at commands.rs:416/422/1866, registry.rs:526-527, github.rs:242/258, git.rs:619 (leave
  those alone, or reuse the helper only where it is the same expression).
- [ ] **Step 2:** unit test: `…:50.6Z` → `"…:51Z"`; `None` → `null`.

### Task A2: `info` of a package gains `versions-released`

**Files:** Modify `src/commands.rs` (`info` 2698-2839; `print_json` 2790-2803, `versions` at 2799).
Test: `tests/json.rs`, `tests/info.rs`, `tests/git.rs`.

- [ ] **Step 1:** Composer: build the map from `cands` (2744) next to `versions` (2754), skipping
  `time == None`.
- [ ] **Step 2:** GitHub/git (2718-2741): insert `c.version → c.time` only when `versions` contains
  `c.version`. A ref, `@branch` target or tagless repo gives a 12-character sha (github.rs:288,
  git.rs:637), which is skipped. `c` is either `locked_candidate(p)` (time = `p.released`, no request,
  835-848) or comes from `candidate_at`/`ctx.candidate`, whose `resolve` runs today already; add no call.
- [ ] **Step 3:** add `"versions-released"` to the JSON; text output unchanged.
- [ ] **Step 4:** tests:
  - Composer mock registry (`Ver { time: Option<String> }`) with `time` on 2 of 3 versions → exactly those 2.
    `ago()` moves with the clock: assert the parsed key set and that values parse as timestamps, or compare
    with the `released` written to skills.lock.
  - GitHub, extend tests/info.rs:110 (ref, no tags) → `{}`; a locked-tag case → one key and no `/commits`
    request in `s.log()`.
  - git, extend tests/git.rs:241.

### Task A3: `outdated` gains `locked-released`, `within-released`, `latest-released`

**Files:** Modify `src/commands.rs` (`outdated` 1817-~1889; rows `[String; 5]` at 1824; `within` 1862,
`latest` 1871; JSON 1873-1880). Test: `tests/json.rs` (:52-55), `tests/git.rs` (:261).

- [ ] **Step 1:** keep the three `Option<Timestamp>`s beside each row: `locked` from `p.released` (every
  source); Composer `within`/`latest` from the `&Candidate`s at 1862/1871; GitHub/git `None`
  (`newest`, github.rs:292-305 / git.rs:644-655, returns versions only; for a GitHub ref its `commit()`
  date is a commit date, not the cooldown time, so it is not used).
- [ ] **Step 2:** emit the keys with `json_time`; `note` text unchanged (apps before this change parse it).
- [ ] **Step 3:** `eligible`: keep the `time + age` computed for the note (1863-1868) as an
  `Option<Timestamp>` and emit it with `json_time`; `null` when nothing waits and for GitHub/git rows. The
  app already decodes it (OutdatedDocument.swift:13) and prefers it to parsing the note (Update.swift:35),
  so app 0.13.0 reads the same value it parses today.
- [ ] **Step 4:** tests: the four keys on a Composer row (tests/json.rs:52-55 already has a waiting
  version: `eligible` equals the time in `note`), `null` within/latest/eligible on a git row.

### Task A4: `status` entries and `info` of a skill gain `released`

**Files:** Modify `src/commands.rs` (`status` JSON 1973-1981; `why_skill` package document at 2847).
Test: `tests/json.rs`.

- [ ] **Step 1:** status: `lock.get(&r[0]).and_then(|p| p.released)`. Dependency (`via`) rows carry the
  real package name and get a time; `"-"` rows and drift rows with no lock entry get `null`.
- [ ] **Step 2:** `why_skill`: `released` from the lock entry `p` in hand; the project and hand-written
  skill documents print `"released": null` too, so every skill document has the key (as D32's other keys).
- [ ] **Step 3:** update tests/json.rs:27, which `assert_eq!`s the whole status entry; add a project-skill
  row expecting `null`.

### Task A5: TUI: no change

The TUI only calls `info --json -- <skill>` (tui.rs:536), where `released` is a string that
`value_lines` (681-697) prints as text, and `rows()` (631-660) reads only `package`/`locked`/`within`.
Check the info pane by eye once.

---

# Part B: macOS app

### Task B1: decode the new keys

**Files:** `macos/Sources/SkillcaskCore/Documents/{InfoDocument,OutdatedDocument,StatusDocument}.swift`.
Test: `macos/Tests/SkillcaskCoreTests/DocumentsTests.swift`, `ContractTests.swift`.

- [ ] **Step 1:** InfoDocument (`versions` :28, CodingKeys :41-58, `init(from:)` :60-78): add
  `case versionsReleased = "versions-released"` → `versionsReleased: [String: String]`, decoded
  `(try? c.decodeIfPresent(…)) ?? [:]`; and `case released` → `released: String?` (skill document).
- [ ] **Step 2:** `OutdatedDocument.Package` (:4-16) uses synthesized `Decodable`: add an explicit
  `CodingKeys` with every key, as SearchDocument.swift:25-27 does for `skills-sh`
  (`lockedReleased = "locked-released"`, `withinReleased = "within-released"`,
  `latestReleased = "latest-released"`). Keep the existing `released` (:15) decoding for older planned
  output but stop relying on it; fix its doc comment and :7 ("the version update would lock" is wrong:
  `within` ignores the cooldown).
- [ ] **Step 3:** `StatusDocument.Entry`: `released: String?` in CodingKeys :25-35 and `init` :37-48.
- [ ] **Step 4:** capture the new CLI into `Tests/SkillcaskCoreTests/Fixtures/<x.y.z>/`: every file of the
  README table, same scenario, a README section. Keep `0.9.4/`. The `@Test(arguments: Fixture.versions)`
  tests then run on both; add one assertion that the new directory decodes a non-empty
  `versionsReleased`, so a silent `try?` failure cannot pass.
- [ ] **Step 5:** ContractTests (`SKILLCASK_BIN`): key presence on a new CLI for `status` entries
  (`released`), `info` (`versions-released`), `outdated` (three keys).

### Task B2: domain model

**Files:** `macos/Sources/SkillcaskDomain/{Update,SkillEntry,ScopeSnapshot,VersionsModel}.swift`.
Test: `macos/Tests/SkillcaskDomainTests/VersionsModelTests.swift`.

- [ ] **Step 1:** `Update` gains `lockedReleased`, `withinReleased`, `latestReleased` (parsed like
  `released`, :91-93), threaded through the private init (:39-50) and `settled(installed:)` (:82-87),
  where the new `locked` is `within`, so `lockedReleased` becomes `withinReleased`.
- [ ] **Step 2:** `SkillEntry` gains `released: Date? = nil`, set where it is built from the status
  entry (ScopeSnapshot.swift:127-131). Other init call sites keep the default (DesignFixtures:239,
  SecurityPreviews:31/43/52, RowPreviews:97, DetailHeaderPreviews:51).
- [ ] **Step 3:** `VersionsModel.init` takes `released: [String: Date] = [:]` (from
  `info.versionsReleased`), stored by `Update.bare` key (Update.swift:124). Built at VersionsTab.swift:66-69
  from `store.packageInfo[package]`; update SkillDetailView, VersionsPreviews and VersionsTabTests.
- [ ] **Step 4:** dates, each falling back to today's rule:
  - `latestReleased` = `update.latestReleased ?? map[latest] ?? update.released`.
  - `installedReleased` = `entry.released ?? (same(installed, locked) ? update.lockedReleased : nil) ??
    map[installed] ?? today` (:123).
  - `inRangeReleased` (:141-146) = `update.withinReleased ?? map[within] ?? today`.
  - `Cooldown.released` (:250): the waiting version is `within` (Update.swift:4-9), so
    `update.withinReleased ?? map[version] ?? today`. Without this the main Composer cooldown case
    (`within != latest`) stays "unknown" in the callout and row (VersionsContent.swift:103, :166).
  - `released(_:)` / `listed(_:)` (:178-193): `map[bare(version)] ?? today`.
- [ ] **Step 5:** fix the existing `v` mismatch: `standing(of:)` compares `text == cooldown.version`
  (:199), but `cooldown.version` is bare (:249) and a real Packagist list reads `v4.3.0`, so the waiting
  version falls through to `.available`. Compare bare forms. Design fixtures hide it (no `v`).
- [ ] **Step 6:** tests: keep `availableWithinTheRange` (:57-64) and
  `listedStandingsForACooldownInACaretRange` (:129-140) unchanged as the old-CLI cases. Add: every row dated
  from the map; `within != latest`; cooldown dated from `within-released`; `v`-prefixed versions (dates and
  the waiting standing).

### Task B3: header strip dates `within`, not `latest`

**Files:** `macos/Sources/SkillcaskUI/Components/DetailHeader.swift` (:235-243, `released` at :239).
Test: `macos/Tests/SkillcaskUITests/DetailHeaderTests.swift`.

- [ ] **Step 1:** the strip offers `DetailActions.updateTarget` (DetailActions.swift:94-99), which is
  `within`, but appends `update.released` (time of `latest`). Use `update.withinReleased`, falling back to
  `released` only when `within == latest`. Add a test for `within != latest` (none exists, nor a fixture).

### Task B4: fixtures, copy, design notes

- [ ] **Step 1:** design fixtures in `Sources/SkillcaskUI/Fixtures/design/`: `info.package.*.json` gain
  `versions-released`; `outdated.api*.json` gain the three keys; `status.*.json` gain `released`; keep
  `outdated.api-note-only.json` as the 0.9.4 shape (DesignFixtures.swift:66). Use midday UTC times so dates
  do not shift a day west of UTC. Refresh DesignFixtures.swift:164-178 comments.
- [ ] **Step 2:** `VersionsTabTests`: :47 now expects a date where the status fixture has one;
  `listLabelsAndDates` (:128-139) gains dated rows. Pass `.gmt` to every new date assertion (formatters
  default to `.current`, Formatters.swift).
- [ ] **Step 3:** `macos/DESIGN.md` Q2 (:185): dates come from D67; "unknown" stays for GitHub/git tags
  other than the locked or shown one, and for CLIs before x.y.z. Refresh comments at
  VersionsModel.swift:10-12 and :51, Update.swift:28, VersionsCopy.swift:6, Capabilities.swift:15-16,
  OutdatedDocument.swift:7/:14.
- [ ] **Step 4:** `Capabilities.shipped`: no entry; detection stays by key presence.
- [ ] **Step 5 (optional):** Add Skill preview (ResultPreview.swift:129) dates the newest version.

---

# Part C: docs, release and checks

- [ ] **Step 1:** D67 row and D32 amendment in `docs/specs/2026-10-19-skillcask-v1.md`.
- [ ] **Step 2:** `docs/guide/commands.md` `--json` paragraph (:33-43): `info` `versions-released`,
  `info <skill>` and `status` `released`, `outdated` `locked-released`/`within-released`/`latest-released`/`eligible`,
  with "`null` when not in hand (a version missing from `versions-released`); no request is made".
- [ ] **Step 3:** ship CLI and app in the same release (the app bundles its CLI). A newer CLI on `PATH`
  with app 0.13.0 is harmless: it ignores the new keys.
- [ ] **Step 3a (at release, after the version bump):** B1 Step 4, the fixture directory of the released
  CLI, plus the ContractTests version gate (`> 0.13.0`) set to that release. Deferred from implementation:
  the README keeps one directory per release, a dev build still reports 0.13.0, and the scenario's package
  (`netresearch/agent-jira-skill`) now resolves to v4.3.2, so the `Fixture.versions` tests that assert
  0.9.4 content (`v4.3.0`) need per-release expectations first.
- [ ] **Step 4:** `cargo fmt --check`, `cargo clippy --all-targets --locked -- -D warnings`,
  `cargo test --locked`, `cargo test --locked --test cli -- --ignored`;
  `cd macos && swift package clean && ./test.sh`.
- [ ] **Step 5:** manual: `skillcask -g info --json -- netresearch/jira-skill | jq '."versions-released"'`
  prints a time for every version Packagist dates. In the app, point Settings → CLI path at the dev build (or
  `swift run`; the locator prefers Settings, then the bundled CLI, then `PATH`, Locator.swift:3) and check
  the Versions tab.

## Decided (2026-11-17)

1. **No dates from GitHub Releases.** A `/releases` date can differ from the later-of-commit-and-release
   time the cooldown uses (github.rs:224), it covers only tags with a Release and only the first 100, and
   it costs a request per `info`/`outdated` against the 60/h limit, which D67's "no request" rule forbids.
2. **`eligible` ships in this change** (Task A3 Step 3): already computed for the note, already decoded by
   the app, which then stops depending on the note's text for new CLIs.
3. **A lock without `released` prints `null`.** skills.lock stays the only source for the locked version;
   registry metadata can change, and a Composer version without `released` in the lock had no `time` in
   the registry either, so a fallback would almost never help.

## Out of scope: separate PR

- **"In range" for an older version.** 1.6.0 with 1.6.1 installed and `^1.6` reads "In range"
  (VersionsModel.swift:79 doc, :213-214; copy VersionsCopy.swift:245), which reads like an update next to
  "Available in range". Add a standing for "older than installed, inside the range", copy "Older, in
  range", and a `listed` test for it (none pins the case today). UX copy only, unrelated to dates.
