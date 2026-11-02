# Skillcask for macOS: design

A native SwiftUI app (macOS 14+) over the `skillcask` CLI (spec D35). It shows the skills of one
scope (My Skills, the CLI's `-g` personal scope, or a project folder) with their state, updates and
audit findings, and runs the CLI's commands for them. It has no package logic of its own: every
answer comes from the CLI's `--json` documents or the plain text of `diff`, and every change is a
CLI run.

The code is the source of truth for everything below: colours, sizes and fonts live in
`Sources/SkillcaskUI/DesignTokens/`, copy in `Sources/SkillcaskUI/Copy/`. The tables here copy
that source; `Tests/SkillcaskUITests/DesignTokensTests.swift` holds the same values, so a token
change fails until both are updated.

## Screens

| Id | Screen |
|---|---|
| S1 | Scope Overview: health strip and cards (Health, Updates, Security, Sources, Policy, Agents) |
| S2 | Skills list: rows with status dot, filter chips, search, sort; empty, no matches, refreshing (not a live refresh: quiet, no fade, no Checking line), offline |
| S3 | Skill detail: header with state and actions, tabs; project, dependency, not managed, abandoned |
| S4 | Contents tab: SKILL.md front matter as a table and the body as read-only Markdown |
| S5 | Security tab: audit findings grouped by rule, reach as chip groups, changed-on-disk actions |
| S6 | Versions tab: installed, within range, latest, cooldown, tag moved |
| S7 | Review Update sheet: per-file diff before `update`; Update All |
| S8 | Add Skill sheet: search, source filter, consent for skills.sh, preview of the provided skills, progress, failures |
| S9 | Adopt sheet: single (known or unknown source) and batch |
| S10 | Remove alert: single and multi |
| S11 | Running: progress in the list header or the sheet, toast, failure banner, integrity failure |
| S12 | Health results popover: problems, warnings, repaired, passed |
| S13 | Onboarding: CLI missing or too old, first launch hints |
| S14 | Settings: General, Search, Updates, Global, Advanced |
| S15 | Activity drawer: one row per run this session with its transcript |
| U1–U5 | App update (D51): sidebar card (consent, available, waiting), update sheet per install method (Homebrew, download, temporary copy), app menu Check for Updates…, check alerts, Settings › Updates app group |

Flows, walked end to end through the screens: F1 first launch, F2 add a skill, F3 update with
review, F4 adopt, F5 fix problems.

## Tokens

Colour is a dynamic `Color` per token (`Color.<name>`), sRGB, resolved per appearance. Selection is
not a token: rows and the sidebar use the system accent (`Color.accentColor`). Text in a status
colour always uses the `.text` variant; the dot colours are only for the 8 pt dot and badge fills.

| Token | Light | Dark | Use |
|---|---|---|---|
| `surfaceWindow` | `#FFFFFF` | `#1E1E1E` | List, detail, sheets |
| `surfaceSidebar` | `#F2F2F4` | `#272729` | Sidebar (system material) |
| `surfaceGrouped` | `#F5F5F7` | `#232325` | Overview background, segmented track |
| `surfaceCard` | `#FFFFFF` | `#2A2A2C` | Cards: lighter than ground, no shadow |
| `surfaceHover` | `#F2F2F5` | `#2A2A2D` | Row hover |
| `separator` / `separatorStrong` | `#E3E3E8` / `#D1D1D6` | `#353538` / `#454549` | Hairlines; chip borders |
| `textPrimary` | `#1D1D1F` | `#F5F5F7` | Text |
| `textSecondary` | `#5E5E63` | `#A1A1A6` | The only grey allowed for 11 pt text |
| `textTertiary` | `#8A8A8F` | `#7C7C82` | Icons and placeholders only |
| `controlFill` / `controlBorder` | `#FFFFFF` / `#CFCFD4` | `#333336` / `#48484C` | Buttons, fields |
| `accent` / `accentSoft` | `#6D4AFF` / `#EEE9FF` | `#8B74FF` / `#2E2750` | Primary, links; active chip |
| `accentLine` | `#CFC3FF` | `#4A3F86` | App-update card border (never `statusUpdate`) |
| `statusOk` dot · text · tint | `#34C759` · `#1B7A35` · `#E9F8EC` | `#30D158` · `#4CD964` · `#17301D` | Ok |
| `statusUpdate` dot · text · tint | `#0A7AFF` · `#0A5FCC` · `#E6F1FF` | `#409CFF` · `#6EB2FF` · `#172A44` | Update |
| `statusWarning` dot · text · tint | `#F5A623` · `#8A5A00` · `#FFF5DF` | `#FFB340` · `#FFC24A` · `#3A2C10` | Warning |
| `statusError` dot · text · tint | `#FF3B30` · `#C42B22` · `#FFECEA` | `#FF6961` · `#FF7B72` · `#3D1F1D` | Error |
| `statusNeutral` dot · text · tint | `#8E8E93` · `#5E5E63` · `#F0F0F2` | `#98989D` · `#A1A1A6` · `#2C2C2E` | Neutral |
| `pillFill` / `pillText` | `#ECECF0` / `#3A3A3F` | `#38383C` / `#D5D5DA` | Kind pill |
| `skeleton` | `#E8E8EC` | `#333336` | Loading bars |
| `selectionSoft` | `#DCE8FF` | `#1E3A66` | Inactive or secondary selection |
| `diffAdded` / `diffRemoved` | `#E6F6EA` / `#FDE8E6` | `#1B3323` / `#3B1F1F` | Diff lines |
| `diffRisk` / `diffInvisible` | `#FFF0C2` / `#F3E8FF` | `#3A2F10` / `#2E2444` | Risky pattern; invisible character |
| `badgeWarningText` | `#3B2600` | `#3B2600` | Count on an amber badge (4.6:1) |

Type (`Font.Token.<name>`): SF Pro, except SF Mono for what the user meets verbatim in a repository
(package names, versions, paths, file names, diff and transcript text). Nothing is under 11 pt.

| Token | Size / line | Weight |
|---|---|---|
| `title` | 22 / 28 | Bold, tracking −0.22 |
| `sheetTitle` | 20 / 26 | Bold |
| `headline` | 15 / 20 | Semibold |
| `body` · `bodyEmphasis` · `bodyMedium` | 13 / 18 | Regular · Semibold · Medium |
| `callout` · `calloutMedium` · `calloutSemibold` | 12 / 16 | Regular · Medium · Semibold |
| `caption` · `captionMedium` · `captionSemibold` | 11 / 14 | Regular · Medium · Semibold |
| `mono` · `monoSmall` | 12 / 16 · 11 / 14 | Regular, SF Mono |

The diff grid draws `monoSmall` on an 18 pt line, the Activity transcript on a 15 pt line.

| Spacing | pt | | Radius | pt |
|---|---|---|---|---|
| `xs` · `s` · `m` · `l` | 4 · 8 · 12 · 16 | | `s` (badges, pills) | 4 |
| `xl` · `xxl` · `xxxl` | 20 · 24 · 32 | | `m` (controls, rows) | 6 |
| `inline` (glyph to words) | 6 | | `l` (cards, callouts) | 8 |
| `cardGap` · `rowGap` | 10 · 10 | | `xl` (sheets) · `pill` (capsule) | 10 · 999 |

| Size | pt |
|---|---|
| Row · sidebar row · with subtitle · toolbar | 52 · 30 · 40 · 52 |
| Column padding · card padding (v / h) | 24 · 12 / 14 |
| Chip · pill (large) · reach chip · status dot | 22 · 16 (22) · 20 · 8 |
| Badge (small) · button (small) · tab · search · mini progress | 18 (16) · 24 (22) · 22 · 26 · 3 |
| Icons: toolbar · sidebar · inline | 13 · 16 · 12 |
| Window min width · sidebar ideal / min · list ideal / min · detail min | 960 · 220 / 180 · 360 / 300 · 400 |
| Sheets: Review Update · Add Skill · Adopt · App Update | 960×700 · 900×660 · 592×340 · 680 wide |
| Settings width · label column · env remove column · env row | 600 · 200 · 40 · 28 |

### Decisions and deviations

Code comments cite these by number.

- **G4** `selectionSoft` and the four diff colours were literal values on the boards; they are
  tokens.
- **G5** White on the system accent (selected rows, pills, badges) is `Color.white`, not a token;
  the amber badge's dark count text is the one extra token, `badgeWarningText`.
- **G9** The column ideals sum to 980 with a fixed detail minimum of 400 (the boards drew 420), so
  at the 960 pt minimum width the list gives first; the user can narrow either column to its
  minimum.
- **G11** The boards use a Medium (500) weight the base scale lacked: the `…Medium` and `…Semibold`
  variants carry it.
- **G13** Mono line heights outside the scale: 18 pt for the diff grid, 15 pt for the transcript.
- **G14** App update (U1–U5, D51) deviates from the U1–U5 boards: no release notes box
  (a `Release Notes on GitHub` button opens the tag page built from the version), one Homebrew
  command (`brew update && brew upgrade skillcask skillcask-app`, Copy Command and Copy and Open
  Terminal), a zip not a dmg (`Open Release Page`, not `Download X`), no CLI-only or CLI-blocking
  variant and no release date. The sheet is 680 wide (U2 draws 740, with notes), its title is
  `sheetTitle` 20 pt (U2: 17), footers are one row, a temporary copy has no Skip and shows in
  Finder only from the primary. Settings' group is `Skillcask app` with no command-line tool line
  and no pre-release switch; Check Now answers inline there, never as a main-window alert.
- **G15** Agent badges (no board): a skill row shows which `[agents] targets` see the skill as 16 pt
  `Pill`s in the `.agentBadge` style: a text monogram (`CC`, `Cu`, `Cx`, `De`; a folder glyph for a
  path target; never a vendor logo). They come from `status.targets` and `doctor`'s per-target link
  problems, indexed once per snapshot (`AgentIndex`, Domain). A missing, wrong or blocked link, or a
  broken or blocked store link, adds a warning glyph, strikes the monogram through and takes the warning tint.
  The badges sit under the row's trailing slot (or its hover controls), so they form one column at
  the row's trailing edge whatever the location's length; the location truncates first. Badges show
  only with two or more targets, or for a broken link (one target would put the same badge on every
  row); never for a not installed row (its state says it), a not managed or package-only row (the
  CLI does not link them), or while `doctor` has not answered or failed. Order
  (`AgentTarget.displayOrder`, the one priority list): Claude Code, Codex, then the other presets in
  `[agents] targets` order, then path targets; the detail's lines and VoiceOver use it too, while the
  Agents card keeps the config order it mirrors. At most three slots: with four or more targets two
  badges and `+N`; a broken link that would fall into `+N` takes the last healthy slot instead (the
  order is kept, a visible problem is not moved); when more links are broken than fit, `+N` counts
  the rest. VoiceOver reads the row value `…; Available to Cursor; Claude Code link
  wrong`. The detail's "Available to" lists every agent with its directory (`~/` in the global
  scope) and a short state (`linked`, `installed` for store agents, `link missing`, `link wrong`,
  `blocked`, `store link broken`, `store blocked`, `not installed`, `checking…`, `not checked`),
  problems in the warning colour, then a hint with "See Health"; dependencies show it too. A broken
  store link of a project skill is the one cause for every agent (the CLI also calls each target
  link wrong); Repair relinks it. A file or folder skillcask did not create at the store path
  (`link foreign`) is `store blocked`: its hint says to move it away, since `doctor --fix` never
  touches a foreign path. After a failed `doctor`, the rows and the detail claim no link from the
  older answer Health keeps (a skill added since would read `linked` unchecked), while the Agents
  card still counts that answer's broken links, as Health lists them: a known problem claims nothing
  healthy. A refresh that fails entirely keeps the snapshot and its link check.
- The toast's shadow (`0 8pt 24pt`, black at 0.16 light / 0.5 dark) lives in `Toast.Shadow`; no
  shadow token exists yet. Cards never have a shadow.

## Open questions

Gaps between the boards and what the CLI prints, with the interim the app ships. Code comments cite
them by number; the numbers have gaps.

- **Q1** `status --json` has no `source`: decoded when a later CLI prints it, "unknown" otherwise.
- **Q2** No document prints a release date: a planned `outdated` key, "unknown" without it.
- **Q3** "Tag moved" is free text in `outdated`'s `note`: matched by its `tag … moved` wording.
- **Q6** Several board values exist in no CLI document (dates, hashes, link targets): file
  attributes where the app can read them, else "unknown" or left out.
- **Q7** `audit` does not list not-managed skills: their Security tab says "not audited" until the
  planned `auditNotManaged` ships.
- **Q9** A segmented picker cannot carry the board's count badge on Versions: plain titles, and the
  strip under the tabs repeats the update.
- **Q10** `via` names packages, the board names requirer skills: resolved from the scope, the
  package name when no skill matches.
- **Q11** Diff flags need findings of the new version; `audit` covers installed files only, so a
  pending update shows no flags.
- **Q12** No board state for an empty filter without a query: "Nothing in <filter>" with Show All.
- **Q15** The board says Reinstall keeps a copy; `install` keeps none, so the app warns and asks.
- **Q19** `status.targets` prints `entries` (as written) and `dirs` (resolved) as two lists that are
  not parallel: store agents get no directory and duplicates collapse. The app pairs them by
  convention (a path entry is its own directory; `claude`, `kiro` and, in the global scope, `junie`
  take their preset directory, which `resolve_targets` always lists in `dirs`; every other entry
  reads the store `.agents/skills`; a repeated entry counts once). An add-only
  `targets.agents: [{entry, dir}]` key (D32), with `dir: null` for the store,
  would replace the convention, kept as the fallback for older CLIs, and a per-skill `links` map in
  `status` entries would replace parsing `doctor`'s link lines.
- **Q18** No command compares installed files with the lock: Review changes and the changed-file
  list are hidden; Reinstall is the only action.

## Interaction

- One main window: a sidebar of scopes (My Skills under Personal, then Projects), the skills list
  and the detail. The window title is the scope's name and path.
- Sheets and the Remove alert are pinned to the scope they were opened for: switching the sidebar
  does not move them, and they close if that scope goes away.
- One mutation at a time per scope (`MutationQueue`): the CLI has no lock of its own. Mutations of
  other scopes and every read run in parallel; the scope's mutating actions are disabled meanwhile.
- Short runs (Check, Sync, Refresh) show progress in the list header; sheet runs keep it in the
  sheet. The outcome is a toast at the bottom of the list column; a failure is a banner with the
  CLI's hint. Exit 4 (integrity) has its own variant and is never retried automatically.
- Activity (⌥⌘L) is a drawer in the list column with one row per run this session: title, command,
  exit word, duration and the full transcript. It opens by itself only from a failure's Details.
- Add Skill's source filter is client-side over one `search` document: All, then one chip per
  allowed repository, skills.sh when searched and any other source the results name, each with its
  count. Single select; clicking the active chip goes back to All. The filter persists across
  queries within a sheet; a new sheet starts on All. A chip with no results is dimmed and disabled
  unless it is the active one. The Skills list's `FilterChipBar` dims Updates offline but keeps it
  clickable; this difference is on purpose, since a dead chip here could only show an empty list.
  Blocked repositories stay non-interactive pills after the chips; their results, and results
  without a source, count only in All. A filter with no results shows "No results from <source>"
  with Show All.
- Settings (⌘,) is the standard Settings window: CLI path and version, the skills.sh switch, GitHub
  sign-in (`auth set` / `auth remove`), the environment table, and the size of the adopted copies.
  Global (no board) lists every key of `-g config --json` with its layer and changes it through
  `-g config`, read-only where the environment wins or `allow-sources` holds a redacted URL.

## Safety

- Package content is data only. The app never runs anything from a package; it reveals package
  folders in Finder but never opens them, and opens a SKILL.md only in the plain-text editor.
- The app reads a SKILL.md itself only at the path `audit` reports, at most 256 KiB, with control
  and invisible characters escaped.
- Every child gets stdin closed, except `auth set`, whose token goes to the CLI on stdin and never
  on the command line, in a run record or in the Activity transcript.
- A project folder without skills.toml runs nothing but `init`, `projects`, `auth` and `--version`;
  the CLI would otherwise act on the nearest parent project.
- Reads have time limits (2 min on disk, 15 min for the ones that talk to registries); mutations
  have none and are cancelled by the user.
- Environment (`EnvironmentPolicy`): no colour, no agent mode, `CI` removed, the usual install
  directories appended to `PATH`, nothing taken from a login shell. The Settings table cannot set
  policy, credentials, token hosts, TLS roots, `PATH`/`HOME`, loader or git variables; proxies and a
  few harmless `SKILLCASK_*` names are allowed. Run records list the names it applied, never values.

## Previews and renders

Every view state is registered in `Sources/SkillcaskUI/Previews/` (`PreviewRegistry`), drawn from
the sample data in `Sources/SkillcaskUI/Fixtures/` decoded through the real Core and Domain types.
`Scripts/render-previews.sh` runs the `SkillcaskRender` tool, which draws each entry offscreen in
light and dark at 2x into `.build/renders/<id>/{light,dark}/<state>.png` and fails on a missing or
blank PNG. Preview ids (`P1-1`, `P2-5`, `P3-8`, …) follow the build plan's task numbering and name
the render folders. `TokensPreview` (id `P1-1`) is the token sheet: every colour as a flat swatch
with its hex, for pixel checks. `SKILLCASK_UI_FIXTURES=1` starts the app on the fixtures with no
CLI.

The original design boards and the build log of this app are kept on the branch
`pr-assets/macos-gui` of the fork `wpazio/skillcask` (paths `design/` and `docs/handoff/`).
