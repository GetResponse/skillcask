# Spec: skillcask — a lockfile-first package manager for AI agent skills

Date: 2026-10-19. Status: v1.

## Problem

Agent skills (a directory with `SKILL.md`, read by Claude Code, Codex, Junie and others) are
copied into repositories by hand or by tools that do not freeze what they install.

- **Vercel Skills CLI** (`npx skills`, v1.7.4, source checked at `vercel-labs/skills@a80e4c9`):
  writes a project `skills-lock.json` with `source`, `ref` (branch or tag) and `computedHash`
  (sha256 of the files), but `experimental_install` re-fetches from `ref`, not from a commit, and
  never checks `computedHash` (`src/install.ts`). A moved tag or branch installs different content
  silently. No semver for git sources, `update` takes the newest, no CI drift check: `skills
  check` is an alias of `update` and changes the install (`src/cli.ts:420`). Needs Node >= 22.20;
  anonymous telemetry on by default.
- **`netresearch/composer-agent-skill-plugin`** (MIT, v2.1.1): a Composer plugin with a package
  convention (`"type": "ai-agent-skill"`, 57 such packages on Packagist), semver, a lock whose
  checksums it now verifies, a per-package trust map, and an `AGENTS.md` index instead of agent
  skill directories. Works only where Composer and PHP are present.
- **microsoft/apm** (v0.35.0): commit pin, sha256 that fails on mismatch, `install --frozen`,
  semver and transitive dependencies. No release cooldown; packages may ship hooks and MCP
  servers (behind an approval gate); needs Python.
- **rulesync** (v41.0.0): commit pin, per-skill sha256 checked under `--frozen`, `--outdated`. No
  semver, no cooldown.
- **Goldziher/ai-rulez** (v5.7.0): digest lock, `--frozen`, `min_release_age` with an
  organisation floor, a Sigstore-signed lock. Packages may carry hooks and scripts.
- **Tessl CLI** (v0.118.0, proprietary): semver, commit pin, an organisation release-age policy;
  no content hash, no frozen mode, telemetry on by default (it may include file contents).
- **ClawHub** (v0.23.3): registry with VirusTotal and LLM scanning; the lock has no hash and there
  is no frozen mode.
- **`gh skill`** (GitHub CLI 2.103, preview): a user-global lock in the Vercel format, no hash
  check, and it edits `SKILL.md` on install.
- **In-house sync scripts**: semver per skill, committed lock, sha256 per package, CI drift check — but bash, tied to one
  GitLab instance and its Generic Package Registry layout.

Supply-chain security practice asks for a committed lockfile, deterministic installs that fail on drift, pinned versions, a cooldown on
freshly published versions, and no install-time code execution. Several tools now lock by
content hash and install frozen; none combines a content-hash lock, a frozen install, a
release-age cooldown, a text diff of updates and data-only packages in one static binary without
a runtime. The 2026-10-26 survey behind this list is in `docs/research/`.

## Goal

One static binary that installs agent skills the way Composer or Cargo install libraries: a
manifest with version constraints, a committed lock with content hashes, frozen installs in CI,
and links into every agent's skill directory. Skills are distributed through the Composer
repository protocol, so Packagist serves public skills and GitLab's Composer registry (or any
static Composer repository) serves private ones, without a new registry.

Success: a repository in any language runs `skillcask install --frozen` in CI and gets
byte-identical skills to the ones committed in the lock, or a non-zero exit.

## Non-goals (v1)

- Composer `require` of skill packages (ignored; skills declare dependencies in `SKILL.md`, D16).
- ~~Installing from plain git repositories or URLs other than GitHub (see D11).~~ Plain git
  repositories over HTTPS since D30 (2026-10-26); other URLs still not.
- Trust prompts: an entry in `skills.toml` is the decision.
- Running any code from a package (scripts, hooks, plugins). Never, not only in v1.
- GitLab Generic Package Registry archive layouts (`.skill` archives + `CATALOG.md`).
- A hosted registry or web UI. A native desktop shell over the CLI is allowed (D35).
- Telemetry.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Rust, single static binary. | No runtime in the target repository (PHP, Ruby, .NET, JS alike); one artefact to sign and verify. |
| D2 | Composer repository protocol v2 is the only backend (plus inline `packages`, D12). | Packagist (public), GitLab Composer registry, Satis and Private Packagist (private) all speak it; one client covers them. |
| D3 | Package convention from netresearch: `"type": "ai-agent-skill"`, `extra.ai-agent-skill`. | Existing packages install unchanged; no competing convention. |
| D4 | Manifest `skills.toml`, lock `skills.lock`, both TOML, project root. | Language-neutral, comments allowed, familiar from Cargo. |
| D5 | Canonical install directory `.agents/skills/<name>`; other agents get relative symlinks. | Codex reads `.agents/skills` directly; Vercel uses the same canonical place; one copy on disk. |
| D6 | The lock pins version, commit reference and two sha256 hashes; `install` verifies both. | Closes the gap in Vercel's lock: what is installed is what was reviewed. |
| D7 | Cooldown `min-release-age` (default 3 days) applies to `add` and `update`. A cooldown the project cannot change (from the environment or enforced, D18) also applies to every install: a locked version whose `released` is inside it (with D28's per-repository values) is exit 1 naming when it becomes eligible; a version without `released` is not held. | Most malicious releases are pulled within days. A project's own cooldown does not reach what it already locked, since the project wrote both; an outer one must, or a lock written under a looser policy installs unchanged under a stricter one. `released` is the lock's word, so a forged one is caught only by reviewing the lock change. |
| D8 | Authentication reads Composer's `auth.json` / `COMPOSER_AUTH`. | Existing GitLab and Private Packagist credentials, including CI job tokens, work as they are. |
| D9 | Publishing supports both one-repo-per-skill (standard Composer) and monorepos (`skillcask publish` builds a static Composer repository). | Many skills live in monorepos; GitLab's Composer registry accepts one package per project. |
| D10 | MIT OR Apache-2.0, no telemetry. | Usual Rust dual licence; nothing leaves the machine except registry requests and, when asked for, the update check of D51 and the installer download of D52. |
| D11 | GitHub repositories are a second source (`github = true`), resolved through the GitHub REST API; the lock format is unchanged. | Most public skills (the ones skills.sh lists) live in GitHub repositories without Composer metadata. Pinning the commit sha plus both hashes keeps D6. skills.sh itself is not used: its search and download APIs answered anonymously on 2026-10-26, but they are undocumented and could change or close without notice. |
| D12 | Repositories may carry every package inline in `packages.json` (Composer v1/Satis format) instead of `metadata-url`; `publish --inline` writes it, `--dist-url` places the zips. | Private monorepos can then be hosted on GitLab with no new infrastructure: `packages.json` lives in git and is read through the raw files API, zips go to the Generic Package Registry, whose file names cannot contain `/`. One file stays small for a few hundred skills. |
| D13 | `--global` manages personal skills: store `~/.agents/skills`, links in `~/.claude/skills` etc., manifest and lock in `~/.config/skillcask`; a skill name clash inside one scope is solved with `rename`, a clash across scopes is a warning. | Agents read personal skills from home and skills have no namespaces. The design is in `docs/specs/2026-10-20-global-and-aliases.md`. |
| D14 | `publish` records the tree hash of each new version in `extra.ai-agent-skill-tree`; without the published zip in `--out`, a version whose `shasum` differs counts as unchanged when its tree matches, and no zip is written for it. | CI that does not keep `dist/` must not fail on every published version when a `zip` or deflate update changes the bytes of the same tree. Downloading every old zip first would cost a request per version on each run. |
| D15 | A repository may set its own `min-release-age`, which overrides `policy.min-release-age` for packages resolved there; GitHub sources keep the policy value. | Internal skills are reviewed in merge requests and published after every merge; a project-wide `"0"` would also drop the cooldown for public sources. |
| D16 | A skill declares dependencies in a top-level `requires:` map of its `SKILL.md` frontmatter; they are resolved from the consumer's repositories (GitHub only with `policy.github-requires = true`), one version per package, and locked with `requires` in a `version = 2` lock. | Skills that call other skills break silently when one is missing. Composer `require` already holds `php` and plugins in existing packages and cannot name GitHub sources; reading the downloaded `SKILL.md` works for every source. The design is in `docs/specs/2026-10-20-skill-dependencies.md`. |
| D17 | A host no Composer source covers is asked from git's credential helper (`git credential fill`), first for the usernames `auth set` stores (`PRIVATE-TOKEN`, then `oauth2`), then without one, on by default, off with `SKILLCASK_GIT_CREDENTIALS=0`; `skillcask auth set <host>` stores a token there. | Tokens then live in the macOS Keychain, the Windows Credential Manager or libsecret instead of a plain-text `auth.json`, with no new dependency: every developer machine has git and a helper. Asked without a username, the macOS Keychain returns the first entry for the host, usually the user's own git login, which the GitLab API ignores and answers 404. |
| D18 | Policy has layers: environment (`SKILLCASK_*`), keys a user `config.toml` lists in `enforce`, the project `[policy]`, the rest of `config.toml`, built-in defaults. Against an enforced key the environment may only tighten (a longer cooldown, `deny-patterns` on, `allow-ranges`, `packagist` or `github-requires` off, sources inside the enforced ones); a looser value is exit 1. `allow-sources` limits sources by name, `packagist`, `github` or URL prefix, at resolution and at install from the lock. With `allow-sources` set, a lock entry's archive comes only from what was checked, for every command that downloads it: an entry whose `repository` is under a GitHub API (the one in use, the trusted one, or the text before `/repos/` in any `https://` entry of the list) must be exactly `<api>/repos/<owner>/<name>` and downloads only `<repository>/zipball/<40-hex commit>`, compared as parsed URLs; a repository of `[repositories]` the list admits only by a prefix downloads only a dist the list admits too; any other entry that is not from Packagist or a repository the list names (by a name entry, never a keyword or a URL) or gives by its exact URL without a trailing `/` only a git checkout of its repository. The rule follows `repository`, not the lock's dist type or path shape. Packagist's and a named registry's dist may be on any host, since registries serve them elsewhere (Packagist: GitHub zipballs), so its host, like its release time, is the lock's word. `init` lists Packagist and GitHub in `[repositories]`; Packagist is always searched last. | Organisations that may only use their private registry need one rule for every project, CI and dependency, which a project cannot loosen unless allowed; a project's CI configuration sets environment variables too, so the environment must not loosen it either. Checking the lock too means a committed lock cannot bypass it. A prefix stands for the organisation that sets it, and a project can declare any registry under one, so only a registry named or given by its exact URL vouches for other dist hosts; names exist only in `skills.toml`, where the project could change the list anyway, and an exact URL is how `config.toml` names one; an entry ending in `/` is a prefix and never names one, and an entry with `/repos/` makes the text before it a GitHub API whatever the project's `github` says (a Composer registry with `/repos/` in its path under such an entry is refused, failing closed). A registry a project declares at exactly an entry without a trailing `/` is still trusted that way. `enforce` guards against what a project brings, not against the user: the environment and the config directory stay theirs, so a rule nobody may skip belongs in a required check on pull requests; the lock is held to `allow-sources` and `allow-ranges`, while the cooldown and `deny-patterns` apply when a version is resolved. The design and threat model are in `docs/specs/2026-10-20-source-policy.md`. |
| D19 | Output has two modes: agent (`--agent`, `SKILLCASK_AGENT`, or detected from `AI_AGENT` / `CLAUDECODE`) prints terse, uncoloured, tab-separated lines and only problems; person gets colour in a terminal (off with `NO_COLOR`), hints on their own line and grouped `doctor` output. | Agents pay for padding and `ok` rows in tokens, people need to see at a glance what failed and what to run next. ANSI codes need no dependency. The design is in `docs/specs/2026-10-20-cli-output.md`. |
| D20 | Every HTTP request is a GET (or git's read-only `upload-pack` POST, D30) and is tried up to 3 times on a connection failure (I/O error or refused connection), 429 or 5xx: after 1 s and 2 s, or after `Retry-After` seconds up to 60 s. A longer `Retry-After`, an HTTP-date `Retry-After` (backoff instead), GitHub's spent quota (`x-ratelimit-remaining: 0`), timeouts, DNS and TLS errors and a body that breaks mid-read are not retried. | One 502 from a registry should not fail `install --frozen` in CI. GETs are idempotent, so retrying cannot repeat a side effect; `publish` only writes files. Waiting out a rate-limit window or a 300 s timeout again would stall CI longer than failing. |
| D21 | Composer `abandoned` (`true` or a replacement package) of a package's newest version is a warning in `add`, `update` (and `install` when it resolves) and `outdated`; `publish` writes it from a `deprecated:` frontmatter key (`true` or `vendor/name`). The replacement is printed only when it is a valid package name, so registry text cannot add escapes or lines. | Composer and Packagist already carry the flag, so authors of one-repo skills set it as for any package. The newest version decides because Composer marks the whole package; a retired monorepo skill gets it by publishing one more version, since published versions are immutable. A warning, not an error: the lock still pins reviewed content. |
| D22 | A `skills.lock` with a line starting with `<<<<<<<`, `=======` or `>>>>>>>` fails with a hint: keep either side, then `skillcask install`. | `install` re-resolves the manifest entries the kept side lacks, so no merge logic is needed; a TOML parse error alone does not say what to do. |
| D23 | Amended by D56. `add`, `update` and `install` when it resolves warn about bidi controls (U+202A-202E, U+2066-2069, U+200E, U+200F, U+061C), zero-width characters (U+200B-200D, U+2060, U+FEFF) and Unicode tags (U+E0000-E007F) in the text (valid UTF-8) files of every skill they lock from a fresh download (list extended by D56), with path, line and code point, five per file and a count of the rest. Not reported: a leading byte order mark and U+200D between two emoji. Installing from the lock, relocking the locked version and `update` resolving a dist with the sha256 already locked do not scan. | Such characters make an agent read other text than a reviewer sees (Trojan Source, ASCII smuggling in tags). A fixed list needs no network and no Unicode tables. Warnings, not errors: right-to-left and Indic text use some of them legitimately. The lock pins content that was already shown. |
| D24 | `skillcask validate [paths]` checks every SKILL.md under the paths (default `.`, found as `publish` finds them, plus symlinks to a directory that holds SKILL.md, so `validate .agents/skills` also checks the project skills linked there. A linked skill is checked whole, but the search never continues through a link, the names it skips apply to links too, and a skill reached by two paths is checked once) against the Agent Skills specification: `name` 1-64 of `[a-z0-9-]`, no leading, trailing or double hyphen, equal to the directory name; `description` 1-1024 characters; `compatibility` at most 500; plus `requires:` and the file rules `publish` applies. It exits 1 on any error and warns about invisible Unicode as D23. `publish` warns about each SKILL.md it skips for lacking `name` or `version`. | Authors and monorepo CI find mistakes before publishing; a typo in the frontmatter used to publish nothing without a word. Install keeps accepting names such as `a--b` (`skill::valid_name`), so existing packages still install. |
| D25 | `outdated --strict` exits 1 when `update` would lock a newer version of a `skills.toml` entry: the same repository, policy, cooldown and constraint (with those of requirers added) as `update`; for a branch or commit entry, a different commit. Versions outside the constraint and dependencies do not count. | A scheduled CI job or bot needs a gate without parsing the table. Using `update`'s resolution means the gate fails only when `update` would change something; dependencies stay out, as in `outdated` (skill dependencies spec). |
| D26 | `info <target>` takes `vendor/name[@constraint]`, `github:owner/repo[@version-or-ref]` or a skill name. For a package it shows the locked version (else the newest `add` would take; `@` for another, cooldown not applied): skills with their descriptions, versions, description, license, `abandoned`, `requires`, and why it is locked. The dist is downloaded and verified (against the lock for the locked version) into the system temp dir; nothing in the project is written. For the locked version the skills (path and name) come from the lock, not from the registry's current metadata. Registry and `SKILL.md` text prints with control and D23 characters as `<U+XXXX>`. A name without `/` is an installed skill: the package that installs it (and its upstream name if renamed), then the `skills.toml` entry or the chain of requirers that brings it in; project and hand-written skills are named as such. | Skill names come from `SKILL.md` frontmatter, so only the archive tells which skills a package has; choosing `skills = [...]` should not need guessing. One command instead of `info` plus `why`: package names contain `/` and skill names cannot, so the argument says which question is asked. |
| D27 | `diff [pkg] [--to <constraint>]` prints a unified diff (Myers, 3 lines of context, no new dependency) of the skill files as installed, from the locked version to the one `update` would lock, or to the newest matching `--to` without the cooldown. Without a package: every `skills.toml` entry with a newer version. The old side comes from the store when its tree hash matches the lock, else from the locked dist (verified); the new dist is verified like `add`'s. Binary files (not UTF-8, or with NUL) print `Binary files differ`; exec bit changes print `old mode` / `new mode`. Control characters and the characters of D23 in lines and paths print as `<U+XXXX>`; changed files are scanned as in D23. A package new to the lock (a manifest entry not locked yet, or a dependency a new version adds) is diffed against nothing. A carriage return prints as `<U+000D>` unless both sides end every line with CRLF, so a line-end change is visible. `update --diff` prints the same diff for each package it changes or adds, before it writes the lock (a diff that fails changes nothing); it does not ask, so `diff` is the review step. Past 1000 edits in one file the diff replaces the whole file; a side over 1 MiB or 10,000 lines prints `Files differ (too large to show)`. Accepted: `info` and `diff` unpack into the system temp dir, which Ctrl-C leaves behind. | A skill is a prompt; reviewing its text before the update is the only real check, and the lock shows only hashes. Printing package text raw would let it drive the terminal or hide a change with bidi reordering. The edit cap keeps memory bounded (the Myers trace grows with the square of the edits); the size cap bounds time, since each Myers step walks the file. The OS cleans its temp dir; trapping signals would need a dependency. |
| D28 | While `config.toml` enforces `min-release-age`, it also binds the per-repository values of D15: a project may lengthen a repository's cooldown, never shorten it. Exceptions live in `config.toml` under `[policy.repository-min-release-age]`, keyed by `https://` URL prefix (longest match wins), and need `min-release-age` in `enforce`. The environment can only lengthen the enforced value (D18), and the floor follows it; repeating it keeps the floor as is. | Without it any project could write `min-release-age = "0"` on a repository and skip an organisation's cooldown. Keys are URL prefixes, as in `allow-sources`, because a repository name means whatever a project calls it. |
| D29 | An `[agents] targets` entry without `/` is an agent preset (`claude`, `kiro`, `junie`, `codex`, `copilot`, `cursor`, …) resolved per scope; agents that read `.agents/skills` get no link. `targets` comes from the manifest, else `config.toml` `[agents] targets`, else `["claude"]`; `init` stops writing it. Links in dropped target directories are removed. | 12 of 15 agents checked read the store, so users should name agents, not learn their directories, and set them once per machine. Paths need a `/` so a typo cannot create a directory. The design is in `docs/specs/2026-10-21-agent-targets.md`. |
| D30 | A skill entry may name a plain git repository, `{ git = "https://host/owner/repo.git", version | ref }` (`add git:<url>[@x]`, key = the last two URL parts), resolved like GitHub (D11): semver tags or a branch, tag or commit, pinned to the commit sha. skillcask speaks git's smart HTTP protocol (v0, stateless `upload-pack`, a read-only POST retried like a GET, D20) itself and fetches the commit at depth 1; every object is checked against its SHA-1 id from the pinned commit down, deltas included. The lock keeps D6's shape: `dist = { type = "git", url = <repository>, reference = <sha> }`, and `dist-sha256` is the sha256 of the sorted lines `<path>\0<mode>\0<sha256 of content>\n` (`644`, `755`, `120000` for a link) of the commit's files. Times are commit dates only; a branch whose head is within the cooldown falls back to the newest first-parent commit before the cutoff among 100, fetched without trees when the server supports `filter`, else it fails. Submodules are skipped; `requires:` and `info` take `git:` targets since D36. `flate2`, already built for `zip`, inflates the pack: no new crate. | GitLab, Bitbucket, Azure DevOps and self-hosted servers hold most private skills outside GitHub, and a Composer registry is one more thing to run. Running the git binary would bring in the user's configuration (global hooks via `core.hooksPath`, filters such as LFS, `core.fsmonitor`) and git's own record of clone vulnerabilities; reading the protocol directly keeps an install data-only, and it is small: packet lines, a pack, deltas. Hashing the file list instead of the transferred pack makes the lock independent of how a server packs or a future skillcask zips. git servers keep no push or release times, so the cooldown is as weak as for GitHub tags without a release: the pinned sha and the review of the lock remain the real check. |
| D31 | Amended by D56. Next to D23, the same commands scan the same files for a fixed list of risky lines and warn with path and line, five per file and a count of the rest: download piped into a shell (`curl`/`wget`/`irm`/`iwr`/`Invoke-WebRequest`/`Invoke-RestMethod` and a `\|` into `sh`, `bash`, `zsh`, `dash`, `iex`, `Invoke-Expression`, `python`, `python3`, `perl`, `ruby`, `node`, also after `sudo`), base64 decoded and run (`base64 -d`, `--decode`, `b64decode`, `FromBase64String` with a pipe into a shell, `eval`, `exec(` or `iex`), SSH keys (`~/.ssh`, `$HOME/.ssh`, `id_rsa`, `id_ed25519`), `/etc/passwd` and `/etc/shadow`, and "ignore previous/prior instructions" phrasings; matched per line, lowercase, whitespace runs folded. `[policy] deny-patterns = true` (a D18 key, so `config.toml` can enforce it and `SKILLCASK_DENY_PATTERNS` set it, only stricter against an enforced value) turns any match into exit 1 before anything is written; `info` and `diff` only warn. | Install-time scanners are common in other skill tools (`docs/research/2026-10-26-landscape.md` §4), and these patterns are how a skill turns an agent against its user. A fixed, documented list is predictable and needs no rules file or network; it catches the careless and the obvious, not a determined attacker, which is why review of `diff` stays the real check. Warnings by default because setup docs legitimately contain such lines; an organisation that prefers false positives to surprises can enforce the error. |
| D32 | `status`, `outdated`, `info`, `search` and `doctor` take `--json` and print one compact JSON document on one line of stdout instead of text, in both output modes (D19), with the same exit code; warnings, notes and errors stay on stderr as text. Keys: `status` {`ok`, `entries`: [{`package` (always a bare name; the text table labels a dependency `name (via requirer)`), `version`, `skill`, `state`, `ok`, `adopt` (D38), `via` (the requirers of a dependency, else `null`)}], `policy`: {key: {`value`, `from`}}, `targets`: {`entries`, `from`, `dirs`, `local` (the `[agents] local` directory; `null` with `--global`, where it does not apply), `agents`: [{`entry`, `dir`}] (each distinct entry once, as written, with the directory it resolves to, also when an earlier entry already named it; `null` for an agent that reads the store `.agents/skills`); `dirs`, `local` and every `dir` are relative to the scope root, the home directory with `--global`}}, every entry listed; `outdated` {`packages`: [{`package`, `locked`, `within`, `latest`, `note`}], `behind`}; `info` {`package`, `source` (`composer`, `github`, `git`), `repository`, `version`, `locked`, `description`, `license`, `abandoned` (`null`, `true` or the replacement), `versions` (all), `requires`, `skills`: [{`name`, `description`}], `why`}, or for a skill name {`skill`, `kind` (`package`, `project`, `hand-written`), …}; `search` {`results`: [{`name`, `description`, `source`, `installs`, `skills`, `requires`}]}; `doctor` {`ok`, `passed`, `problems`, `fixed`, `warnings`}. Absent values are `null`, not `-`. Package text is escaped as in the terminal (`<U+XXXX>`, D26) and URLs are redacted. Keys are only added, never renamed or removed, within a major version. | Agents and CI read these commands; parsing tables breaks on every wording change and costs tokens. One document per command rather than one object per line: the outputs are small, have a header (`ok`, `policy`) next to their rows, and `jq` reads either. Escaping keeps the guarantee of D26 that package text cannot reorder what a reader sees, which matters as much to an agent reading JSON. |
| D33 | `action.yml` at the repository root is a composite GitHub Action: it downloads `skillcask-<target>.<ext>` of release `v<version>` for the runner (Linux x64 musl, Linux arm64, macOS arm64 and x64, Windows x64), checks the sha256 the release lists and, unless `verify-attestation: false`, the build provenance attestation with `gh attestation verify`, adds the binary to `PATH` and runs `skillcask <args>` (default `install --frozen`) in `working-directory`. `version` defaults to the tag the action is used at; at a branch or sha it must be given. It uses no other action; `args` reaches the shell only through the environment, split on whitespace. | CI is where `install --frozen` matters, and every other skill tool with a lock ships an action. A composite action needs no build of its own and no third-party action to pin. The sha256 alone only guards the download, since it comes from the same release; the attestation ties the archive to this repository's release workflow. Taking the version from the tag keeps the binary and the action on one pinned release. |
| D34 | `skillcask audit` reads every skill on disk: locked ones and hand-written ones in the store, and the project skills. For each it lists what the text reaches: `commands` (first words of every command, split on `\|`, `&&`, `\|\|` and `;`, in Markdown code blocks tagged `bash`, `sh`, `shell`, `zsh`, `fish`, `console`, `terminal`, `powershell`, `pwsh`, `ps1` or `cmd`, with prompts, `sudo`, shell keywords and leading `VAR=` assignments skipped, and comments, continuation lines, heredoc bodies and words that cannot name a program (capitals outside PowerShell blocks, `)`, `:`, `/`) left out), `network` (hosts of `http(s)://` URLs), `paths` (tokens starting with `~/`, `$HOME/`, `%USERPROFILE%`, `C:\` or `/etc`, `/usr`, `/var`, `/opt`, `/tmp`, `/Users`, `/home`, `/root`), `env` (upper-case `$NAME`, `${NAME}`, `$env:NAME`, `x.env.NAME`) and `scripts` (executable files and `sh`, `bash`, `zsh`, `ps1`, `cmd`, `bat`, `py`, `js`, `mjs`, `rb`, `pl`). Findings, with rule ids that are part of the output: `modified` (a locked skill not installed or not matching its tree hash, level error), `risky-pattern` (D31) and `invisible-character` (D23), both warnings, every occurrence. Exit 1 on any finding. `--json` (D32 rules) prints {`ok`, `skills`: [{`skill`, `kind` (`package`, `hand-written`, `project`), `package`, `version`, `path`, `findings`: [{`rule`, `path`, `line`, `message`}], `commands`, `network`, `paths`, `env`, `scripts`}]}; `--sarif` a SARIF 2.1.0 log with one result per finding, paths relative to the project root (the home directory with `--global`). | Install-time warnings show only new content, once; a reviewer and CI also need to see what is installed now, including hand-written skills nobody locked, and what each skill asks an agent to touch (as HarnessKit's permission view does). Reading the text keeps it data-only and offline; it is a list for a reviewer, not a sandbox, so reach never fails the command. SARIF is what GitHub and GitLab code scanning read, so findings land in the merge request without a converter. |
| D35 | `macos/` holds a SwiftUI app for macOS 14+, a Swift package built with `swift build` and wrapped by `macos/bundle.sh` into a universal, ad-hoc signed `Skillcask.app` that carries a universal `skillcask` built from this repository at `Contents/Helpers/skillcask`; it is not part of the Rust build; releases ship it (D50). It runs the `skillcask` binary (the path from its settings, else the bundled one, else `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`; never a file that is the app itself) with stdin closed, needs 0.9.4 or newer, and reads only the `--json` documents of D32 (`status`, `outdated`, `info`, `search`, `doctor`, `audit`), of D40 (`projects`, for a folder the user picks), of D48 (`-g config --json` and `-g config --json -- search.skills-sh`; it never reads or writes `config.toml` itself) and of D51 (`self-check --json`, which it runs from "Check for Updates…" and daily once the user said yes), the plain text of `diff <package>` (and `diff --to <version> <package>` for a version still inside the minimum release age), shown before `update <package>`, and the one `SKILL.md` of the selected skill at the `path` `audit` reports (at most 256 KiB); besides, it only lists the size of `<config>/adopted` (D38) and, for D51, checks its own bundle path, symlinks resolved (`/Applications/Skillcask.app`, `/AppTranslocation/`, inside `<prefix>/Caskroom/skillcask-app`), and whether `<prefix>/Caskroom/skillcask-app` exists for `/opt/homebrew` or `/usr/local`; and, for the selected scope, it watches with FSEvents, without reading their content, the manifest, the lock, `config.toml`, the store, the project skills directory (`status`'s `targets.local`, `.skills` from a CLI that does not print it) and the target directories `status` reports (heavy project folders such as `.git` and `node_modules` excluded, never the whole home folder), and refreshes as D53 says. It runs `init`, `install`, `add` (`--adopt` for a not-managed skill in the global scope), `update`, `remove`, `doctor --fix`, `-g config search.skills-sh <bool>` (its Settings switch), `-g config -- <key> <value…>` and `-g config --unset -- <key>` (Settings › Global: every key `-g config --json` lists, with its layer; a key the environment sets and an `allow-sources` holding a URL, which the document prints redacted, are read-only; an enforced key has no Unset, since the CLI refuses it while `policy.enforce` lists the key; the CLI's refusal is shown under the key, for `allow-sources` with user names, passwords and the queries of typed values masked, and the list is read again after every change) and `auth set`/`auth remove` (the token only on stdin) as given, showing their output and exit code. In a project folder without `skills.toml` it runs nothing but `init`, `projects`, `auth` and `--version`, since the CLI would act on the nearest parent project. Reads that stay on disk and `self-check` are cancelled after 2 minutes, reads that reach a registry (`outdated`, `diff`, `info <package>`, `search`) after 15; changes have no limit and are cancelled by the user. It reveals package folders in Finder but never opens them, and opens a `SKILL.md` only in the plain-text editor. With no skill selected it lists `status`'s `repositories` (D42); when `search` reports `"skills-sh": null` it asks whether to also search skills.sh and searches again with `--skills-sh --remember` or `--no-skills-sh --remember`, and shows each result's `source` and `installs`. Keys a 0.9.4 CLI does not print leave those parts out. A failed run shows in its output pane; `audit` exiting 1 with its document is not a failure. `-g` is a sidebar entry (My Skills). It has no logic, network access or telemetry of its own. | People who do not live in a terminal still manage skills, and a list with states and updates reads faster than three tables. Going through the CLI keeps one implementation of every rule, check and hash, so the app cannot install anything the CLI would refuse, and D32's add-only keys let an older app read a newer CLI; `status`'s `targets.agents` gives each agent's directory, so the app needs no copy of the presets. The minimum is 0.9.4, the first release with `config` (D48) and `status`'s `via`: the app was not released before it, so it carries no second way to read or write settings for older CLIs. Native rather than a web UI keeps the "no hosted registry or web UI" non-goal: nothing listens on a port and nothing is served. |
| D36 | `requires:` keys and `info` take `git:https://host/owner/repo.git` (`requires:` also `#skill` for one skill), named and resolved as a D30 entry; such a dependency needs `github-requires = true` like a GitHub one, and two requirers (or the manifest entry) naming one package from different GitHub or git URLs is a conflict. `outdated` notes, and warns about, a locked GitHub or git tag that now names another commit (`tag v1.2.0 moved from <sha> to <sha>`); `update` warns whenever it relocks the same version with other content, for any source. Branches are not checked: a branch is expected to move. | Teams that host skills on GitLab or a self-hosted server could depend on them only through a Composer registry. A moved tag is how a compromised or careless maintainer swaps content under a version a reviewer already approved (rulesync detects it for locked commits); `install` still installs the locked commit, so the danger is the next `update`, which these warnings make visible before anyone accepts it. |
| D37 | When a GitHub or git repository (skills discovered, D11, D30) has two skill directories with the same name, the one with fewer path components wins and `add`/`update` say so (`skill "x" is in skills/x and plugins/p/skills/x; using skills/x`) when the skill is selected, as a note when the other copy is under `plugins/` (the expected bundle layout) and a warning otherwise; equal depth still fails. A Composer package declares its paths, so a duplicate there stays an error. | Repositories that ship a plugin bundle next to their skills (`skills/x` and `plugins/<p>/skills/x`, as in public skill collections) could not be installed at all, not even one other skill from them. The top-level copy is the one such repositories present as the skill, and the one `npx skills` installs; the lock records the chosen path, so `install` never has to choose again. |
| D38 | Global scope only: `status` lists every skill directory in the store or a target that is neither locked nor in the managed list as `not managed`, a healthy state (exit code unchanged); `status --json` entries gain `adopt`, the `github:owner/repo/skill` source recorded for that name in `~/.agents/.skill-lock.json` (the lock of `npx skills`), else `null`. `add --adopt` (refused without `--global`) moves what stands at the new package's skill names and is not skillcask's (the store dir, and target entries other than links into the store) to `<config>/adopted/<unix time>/<path>` before installing and reports it in one line (`adopted <n> skill(s): copies moved to <dir>/`); a name another locked package provides is left to the usual conflict. | Personal skills often come from other installers first; an app or user that sees an empty list concludes skillcask is broken, and the only way in was to delete the copy and `add` again. Moving instead of deleting keeps local edits recoverable; the config directory is outside every agent's skill directories, so the old copy is not loaded as a second skill. Project scope keeps hand-written skills (`docs/specs/2026-10-20-global-and-aliases.md`) and has no adopt: there a name clash is a repository decision, made with `rename`. |
| D39 | `diff --from <file> [pkg]` (not with `--to`) compares the lock in `<file>` (`-`: stdin) with `skills.lock`: for each package whose `dist-sha256` or skills differ, the D27 diff from the old entry (store or verified old dist) to the new one, after the new dist passes the checks `install` makes (`dist-sha256`, each skill's `tree-sha256`, `[policy]` on its repository); a package only in the old lock prints `<name> <version> (removed)`. Nothing is installed or written. skillcask reads a file, never a git revision. | A reviewer of a lock change sees new versions and hashes, not the prompt text they bring (the drawback raised against lockfiles in review). `diff` showed only what the next `update` would do, before the lock changed. Taking a file keeps skillcask free of the git binary (as D30), and every CI already has the target branch at hand; the verification means the diff is what `install` would place, or the same error. |
| D40 | `projects [dirs…] [--json]` lists every directory that holds `skills.toml` under the given ones (default: the current one), the given ones included, at most 6 levels down, as absolute paths (`std::path::absolute`, not canonical); it enters no hidden directory, `node_modules`, `vendor`, `target`, `Library` or symlink, skips unreadable directories, and reads nothing but directory listings. `--json` prints `{"projects":[{"path":…}]}`. Not with `--global`. | A user with many repositories cannot tell which use skillcask, and the macOS app (D35) needs that list without a disk walk of its own, which would be logic outside the binary. The skipped directories hold dependencies or caches, never a project of their own, and are most of the time a walk takes; the depth limit keeps a scan of a home directory to seconds. Canonical paths on Windows start with `\\?\`, which other tools and people do not take. |
| D41 | `skillcask ui` is a terminal UI (ratatui on crossterm) for Linux, Windows and macOS with no package logic of its own: it runs its own binary (`std::env::current_exe()`) as a child with stdin closed, `NO_COLOR=1`, `--global` for the global scope and the project root as working directory, reads only the `--json` documents of `status`, `outdated`, `info`, `audit`, `doctor`, `search` and `projects`, and shows the stdout, stderr and exit code of `init`, `install`, `add` (`--adopt` prefilled from a `not managed` entry's `adopt`), `update`, `remove`, `doctor --fix`, `diff` and `--global config search.skills-sh` (the repositories view shows `status`'s `skills-sh` and `S` flips it, D48). `update` always shows `diff <pkg>` first and asks; `remove` asks. The SKILL.md shown is read from `info`'s `path` (now also given for a package's skill), at most 256 KiB, and every text from a child or a skill passes `shown` (D26) before it reaches the terminal. It refuses to start when stdout is not a terminal (exit 1). No listener, no port, no telemetry. | The macOS app (D35) left people on Linux and Windows with the CLI only. Running the binary keeps one implementation of every rule, hash check and policy, as in the app; a second one would drift. A terminal UI needs no server, which keeps it out of the web UI non-goal and away from anything another process could call. ratatui and crossterm are the common Rust choice and support the Windows console; escaping matters because a SKILL.md is package text and could otherwise move the cursor or write the clipboard. |
| D42 | `search` also asks skills.sh (`GET https://skills.sh/api/search?q=<query>&limit=20`, the API `npx skills find` uses) when `--skills-sh` is given or `config.toml` has `[search] skills-sh = true`, and prints its results after the registries' as `github:owner/repo/skill` with the install count; entries whose source is not `owner/repo` or whose skill id is not a skill name are dropped. Off by default: the first `search` in an interactive terminal with neither set asks once and saves the answer; `--remember` saves `--skills-sh` / `--no-skills-sh`, also without a query; `skillcask -g config search.skills-sh true\|false` sets it and `--unset` forgets it (D48); `--json`, agents, CI and pipes never ask and treat unset as off. A skills.sh failure or bad JSON is a warning. It is not asked when GitHub is off or `allow-sources` admits no GitHub repository (a note with `--skills-sh`). `search --json` results gain `source` (repository name or `skills.sh`) and `installs`, the document `"skills-sh"` (`true`, `false`, `null` = never decided); `status` lists the repositories in use with type, URL and whether `allow-sources` admits them (`status --json` `repositories`: [{`name`, `type`, `url`, `allowed`}]) and the setting (`search.skills-sh = true (config.toml)` or `not set`; `status --json` `"skills-sh"` as in `search`). Install still goes through the GitHub API (D11). | Most public skills are on GitHub and listed by skills.sh; Packagist search misses them. Opt-in because a third party receives the query. `config.toml`, not `skills.toml`, because it is a personal choice, not a repository's. Only search uses skills.sh, so D11's concern holds: if the API changes or closes, search loses one source with a warning and nothing that installs or locks breaks. |
| D43 | `GITHUB_TOKEN`/`GH_TOKEN` go only to the host of the GitHub API the user or the runner names: `SKILLCASK_GITHUB_API`, else GitHub Actions' `GITHUB_API_URL`, else `api.github.com`. A `github` url set in `skills.toml` gets a token only from `auth.json`, `COMPOSER_AUTH` or git's credential helper, which are keyed by host. `"github"` in an `allow-sources` from the environment means `<that api>/repos/` only; in one that `config.toml` enforces it means `https://api.github.com/repos/` only, whatever the environment says, and GitHub Enterprise is enforced by its prefix. | Without it any project could write `github = { type = "github", url = "https://evil.example" }` and a CI job holding the token (`update`, `outdated`, `diff --from` in a pull-request pipeline, `install --frozen` through the zipball URL) would send it there before the lock is verified, and the same line widened an enforced `"github"`. Host-keyed credentials already cannot leave their host, as for git sources (D30); GHE under GitHub Actions keeps working through `GITHUB_API_URL`. GHE named only in `skills.toml` and authenticated only by `GITHUB_TOKEN` outside GitHub Actions needs `SKILLCASK_GITHUB_API` or a host-keyed token. The enforced alias ignores both variables because the environment may only tighten an enforced key (D18). |
| D44 | Requirers widen a manifest entry's `skills = [...]` with the skills they name (all of them when one names none), as they already choose the skills of a package with no entry; the manifest is not rewritten, the lock records what is installed. It replaces D16's exit 1 for a required skill outside the selection. | The exit 1 protected nothing: without the skill the requirer is broken, and the fix was always to add the name by hand. Users who picked a few skills of a large GitHub package hit it as soon as a skill from another registry required one more. |
| D45 | A personal skill (`~/.agents/skills/<name>` or a home target) whose tree hash equals the project's locked skill of that name is not reported: no warning in `install`/`doctor`, no rename offered at `add`. Any other personal copy with that name still is (D13). In a terminal, `add`, `install` and `update` offer no rename at all while a conflict remains that a rename of the new package cannot solve; the error comes first. A run removes its own `.skillcask-run-<pid>` when it exits, on success and on error. | One team skill installed both globally and in a project is the common case after a migration and is harmless: the agents load the same text. Twelve warnings for it buried the ones that matter, a personal copy that differs. Questions answered before an unrelated error are lost and get asked again. Run locks left by failed runs showed up in `git status` before the first install wrote the `.gitignore` block. |
| D46 | `install` ends with `✓ <n> skill(s) match skills.lock` for a person, as `status` does, also when it had nothing to do; an agent still gets no line (D19). | A silent exit 0 after a no-op install looked like a hang or a bug to people migrating from grskill, whose sync always printed. Agents keep the D19 rule of problems only. |
| D47 | `add --adopt --all` (global scope, no package argument) adopts every `not managed` skill whose `github:` source `npx skills` recorded (D38): one `add` per repository with all of its adopted skills added to the entry's `skills`, so one resolve each; a failed repository is reported and the others go on, exit 1 at the end. Skills without a recorded source stay where they are and are listed with the hint to add their source by hand. `skillcask ui` runs it on `M` after a confirmation. | Migrating from `npx skills` leaves dozens of unmanaged copies, often of one repository; adopting them one `add` at a time cost a GitHub resolve per skill and many prompts. Guessing a source for a skill nobody recorded would install someone else's code under a familiar name, so those are only listed. |
| D48 | `skillcask config` reads and changes settings without opening the file: without `--global` the `[policy]` keys and `[agents] targets` of `skills.toml`, with it `config.toml`, which also takes `policy.enforce` and `search.skills-sh`; those two without `--global` are an error whose hint is the same command with `-g`. `config` lists every key with its effective value and layer (`skills.toml`, `config.toml`, `config.toml, enforced`, `environment`, `default`; with `--global` as an empty project would see them), `--json` as {`file`, `settings`: {key: {`value`, `from`}}}, `null` for a key nothing sets. `config <key>` prints the value (exit 1 when not set), `config <key> <value…>` sets it (`true`/`false` as booleans, one argument per entry of a list), `config --unset <key>` removes it. A change is made with toml_edit so comments and the rest of the file stay, checked as the next command would read it (for `skills.toml` with `config.toml` and the environment, so an enforced key cannot be loosened) and written atomically only if valid; the config dir is created. `config edit` opens the file in `$VISUAL`, else `$EDITOR`, else `vi` (`notepad` on Windows), run as a shell command like git (`sh -c`, `cmd /S /C` on Windows) so arguments work and a path with spaces is quoted, and checks it afterwards: an invalid file is reported (exit 1) and left as edited. Tables (`[repositories]`, `repository-min-release-age`) only through `edit`. | Changing a setting meant finding the file (`config.toml` moves with `SKILLCASK_HOME` and `XDG_CONFIG_HOME`) and knowing its schema; `config` names the key, the file and the layer that wins. Writing through the same checks as reading means a typo fails at once instead of breaking the next `install`. Personal keys stay out of `skills.toml` for the reason of D42. An edit is not reverted, so a long change is not lost to one mistake. |
| D49 | `publish` records a version's `requires:` in its metadata as `extra.ai-agent-skill-requires` (a map of package to constraint) and adds it to versions published before, whose content is unchanged. `search` shows it as `[+N packages]`, and a package that lists more than one skill as `[N skills]`; `--json` adds `skills` (the count, `null` from Packagist or skills.sh) and `requires` (the map, `{}` when none). Resolution still reads `requires:` from `SKILL.md` (D16): the metadata key is informational. For a person, `search` prints the description up to its first sentence and at most 100 characters; an agent gets it whole. Matches after the vendor rank first, and the 30-match cap counts only packages whose metadata needs a request: inline `packages` are all listed; past the cap `search` says to narrow the query. | A collection is a skill whose `requires:` names the skills of a set; without a mark it looks like any other package, and its contents are only in the zip. A registry's descriptions run to a paragraph (they are what an agent reads to choose a skill), so a person searching a vendor got a wall of text, and the cap dropped half of a registry that costs no request to list. Trusting metadata for resolution would let a registry change dependencies without changing the reviewed `SKILL.md`. |
| D50 | Every release tag also ships the macOS app of D35: `publish-macos-app` in `release.yml` bundles the released darwin CLIs (joined with `lipo`) into `Skillcask.app`, signs it with a Developer ID, notarizes and staples it, and attaches `Skillcask-X.Y.Z-macos-universal.zip` with its `.sha256` to the GitHub Release, with `skillcask-app-installer.sh` (`macos/install-app.sh`: downloads that zip, checks its sha256 and `spctl`, moves an earlier copy to the Trash, refuses a Homebrew install); it runs in the GitHub environment `release`, which holds the signing secrets, waits for a reviewer and deploys only from `v*` tags. For releases that are not pre-releases, `publish-homebrew-cask` then writes the cask `skillcask-app` (that zip, `depends_on formula: "getresponse/tap/skillcask"`) to `GetResponse/homebrew-tap`, without the signing secrets. The app keeps preferring its bundled CLI (D35). `skillcask app` opens the app through LaunchServices (`/usr/bin/open -b io.github.puniserv.skillcask`, stdin closed, no arguments) and, when none is installed, exits 1 naming the cask and the zip; on other systems it exits 1 and points to `skillcask ui`. Details: `docs/specs/2026-10-28-macos-app-release.md`. | Gatekeeper rejects a downloaded app that is only ad-hoc signed, and Homebrew casks quarantine what they install, so only a notarized app opens like any other download; stripping the quarantine would turn off the check instead of passing it. A cask next to the formula, not one replacing it, keeps `brew install getresponse/tap/skillcask` the same on macOS and Linux. The bundled CLI keeps the app and the CLI it reads at one version. Opening by bundle id finds the app wherever it was put, and starting nothing but `open` keeps the command free of logic. |
| D51 | `skillcask self-check [--json]` says whether a newer skillcask is released: one anonymous `GET https://raw.githubusercontent.com/GetResponse/homebrew-tap/main/Casks/skillcask-app.rb` (`SKILLCASK_SELF_CHECK_URL` replaces it for tests and mirrors) over HTTPS with no credential of any kind (D43's tokens never go with it) and the CLI's User-Agent (`skillcask/<version>`), at most 64 KiB, and takes its `version "X.Y.Z"` only when it matches `^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`; it prints the running version and the latest; `--json` (D32 rules) prints {`version`, `latest` (`null` when unparsable), `newer` (SemVer precedence, `false` when `latest` is `null`)}. It never runs by itself and writes nothing; network errors exit 3 as elsewhere. The macOS app (D35) runs it from "Check for Updates…", and daily only after the user said yes once (it asks in the sidebar; Settings › Updates switches it), and shows the commands for how it was installed, built in the app, never taken from the response: Homebrew `brew update && brew upgrade skillcask skillcask-app`, else the release page `https://github.com/GetResponse/skillcask/releases/tag/v<latest>`. It copies the command (and may open Terminal), opens the release page or, for a temporary copy, shows the original in Finder; it shows no release notes and installs nothing. | Notify-only keeps the rejection of in-app updaters (`2026-10-28-macos-app-release.md`): skillcask does not update itself (amended by D52 for installer-script installs), Homebrew and the zip do. The CLI makes the request so the app keeps no network code of its own (D35), and Linux and Windows get the same check. Anonymous because a token would tell GitHub who checks; opt-in because, as for skills.sh (D42), a third party learns the IP and the time. The cask file because `publish-homebrew-cask` writes it only once the notarized zip exists, so `brew upgrade` and the download both have the version, and raw files do not count against the REST API's anonymous limit. The release body is dist's install text (`curl … \| sh`, D31), not notes, and nothing remote reaches the clipboard. |
| D52 | `skillcask self-update [--dry-run]` takes the latest version from D51's request (none newer: exit 0) and finds how this skillcask was installed from `current_exe()` with symlinks resolved, first match wins: inside `*.app/Contents/Helpers/` (the app; a cask install when `<prefix>/Caskroom/skillcask-app` exists for `/opt/homebrew` or `/usr/local`, as in D51), under `/Cellar/`, under `/.bun/`, under `/node_modules/`, listed in `$CARGO_HOME/.crates2.json` with the exe at `<cargo_home>/bin/skillcask`, then a dist receipt (`$XDG_CONFIG_HOME/skillcask/skillcask-receipt.json`, `%LOCALAPPDATA%\skillcask\` on Windows) with `install_layout` `cargo-home` and the exe at `<install_prefix>/bin/skillcask`. Only that last case on Unix updates, unless `SKILLCASK_SELF_UPDATE=0`: with `sha256sum` on `PATH` (else exit 1, since dist's script then skips its archive check), it downloads `<base>/v<latest>/skillcask-installer.sh` anonymously (D51's `Http::anonymous`, at most 256 KiB; `<base>` is `https://github.com/GetResponse/skillcask/releases/download`, which `SKILLCASK_SELF_UPDATE_URL` replaces with a warning naming it), writes it to an unnamed temp file and `exec`s `/bin/sh -s` with it as stdin, every `SKILLCASK_*`, `INSTALLER_*` and `CARGO_DIST_*` variable removed, then `SKILLCASK_INSTALL_DIR=<install_prefix>` and `SKILLCASK_NO_MODIFY_PATH=1` set; the installer's exit code is the command's. Every other case prints `skillcask X -> Y: installed with <method>; update with:` and one pasteable command as the hint (cask `brew update && brew upgrade skillcask skillcask-app`, app without the cask its tagged `skillcask-app-installer.sh` with `SKILLCASK_VERSION`, formula `brew update && brew upgrade skillcask`, `npm install -g skillcask@latest`, `bun add -g skillcask@latest`, `cargo install --locked skillcask`, the installer's tagged `curl … | sh`, on Windows `powershell -ExecutionPolicy Bypass -c "irm …/v<latest>/skillcask-installer.ps1 | iex"`), or for an unknown install the release page, and exits 1: nothing was updated. No prompt; `--dry-run` prints what would run and runs nothing. Details: `docs/specs/2026-10-30-self-update.md`. | People rarely remember how they installed, and only the installer script can be re-run without fighting a package manager. `.crates2.json` goes before the receipt because dist and `cargo install` both write `~/.cargo/bin`. `exec` means no skillcask process runs while the installer replaces the binary (Linux `ETXTBSY`, macOS signed pages). The script reads `SKILLCASK_DOWNLOAD_URL`, `SKILLCASK_GITHUB_TOKEN`, `INSTALLER_BASE_URL`, `CARGO_DIST_FORCE_INSTALL_DIR` and more to change where archives come from, which token goes there and where it installs, so only what this update decides reaches it; `/bin/sh` is not looked up on `PATH`. The tagged URL and a base rather than a full override install the version D51 reported; the script checks each archive's sha256 and rests on HTTPS to github.com like the first `curl \| sh`. It is skillcask's own release artifact, not package content, so the data-only invariant holds. `SKILLCASK_SELF_UPDATE=0` lets a managed machine keep updates to its admin; skillcask then prints the command. Windows locks a running `.exe`, and `brew`/`npm`/`cargo` may need `sudo` or another `PATH`, so those get the command to paste. `axoupdater` would bring its own HTTP stack next to `Http`. Amends D51's "skillcask does not update itself" for installer-script installs, and D10. |
| D53 | The app of D35 refreshes the selected scope by itself when its files change (live refresh): FSEvents over the paths D35 lists, filtered off the main thread, so a change elsewhere in the project (sources, `node_modules`, a build's rescans) never reaches the window; a relevant change waits 0.7 s for quiet (a burst is one refresh), then runs `status`, `audit` and `doctor` again quietly: no fade, no "Checking…", no Activity row, the selection and the shown detail kept, and never `outdated`, so it stays offline. A refresh in flight is never cancelled or superseded by one: changes during it, or during ⌘R, give exactly one more after it. Changes seen during the app's own mutation, its refresh, or within 2 s after that refresh ends are taken as the app's own writes and dropped, not deferred: a change made in a terminal in those seconds shows only at the next change, the next activation or ⌘R. Returning to the app refreshes the selected scope the same quiet way when it was read more than a minute ago, once for all windows. A missing directory outside the project root and the config directory is watched only once a refresh finds it. Only the selected scope is watched, and there is no setting. | A list that silently goes stale after `skillcask add` in a terminal, an agent writing a skill or a `git pull` loses the trust the lock is meant to build, and other skill managers refresh by themselves. Quiet, because nobody asked for it: fading the list or adding an Activity row every few seconds while an agent works would be noise, and only a user's ⌘R or a mutation earns a row. Offline, because a network check is never implicit. The debounce turns one `add`, which writes many files, into one refresh. The settle window is the cheap way to tell the app's own writes, which its mutation refresh already read and which FSEvents reports a latency and a debounce later, from foreign ones; deferring them would fade the list twice after every mutation, and a foreign change in the same two seconds is rare and caught by the next event or activation. Activation is the net for what no event reported (a network volume, which FSEvents does not watch, or a change while the stream restarted for new roots). No setting: it reads only what ⌘R reads, runs only the read-only offline commands, writes nothing, so it cannot trigger itself, and costs no more than ⌘R. |
| D54 | The repository lives at `GetResponse/skillcask` (moved from `puniserv/skillcask` with GitHub's transfer, which redirects the old URLs). Every URL to the repository, its releases and its attestations names the new owner, cased as GitHub has it: npm checks `repository.url` against the provenance case-sensitively. The tap moved the same way, to `GetResponse/homebrew-tap`: commands name it `getresponse/tap/...`, D51 reads its cask there and the cask depends on `getresponse/tap/skillcask`. The app's bundle id `io.github.puniserv.skillcask` stays. The action of D33 checks the attestation as `GetResponse/skillcask`; for releases up to 0.10.2 only it looks under the owner `puniserv` and requires the signer `puniserv/skillcask`. | The redirect keeps installed binaries, old action tags and old links working, so nothing has to break on the move. A tap added as `puniserv/tap` keeps updating through the redirect, but Homebrew cannot hold both names: with both tapped, short names fail with "Formulae found in multiple taps", and the new cask's dependency is from a tap Homebrew does not trust. Those users move once (README); the bundle id keys the app's preferences and its notarization. An attestation names the repository it was built in and stays with the owner it was made under (the transfer does not move it), so old releases verify only there. |
| D55 | `skillcask audit --advisories` also asks the sources of the locked packages, over the network, what is known about them. A Composer repository whose `packages.json` names `security-advisories.api-url` (Packagist does) gets a GET with `packages[]=<name>` for its locked packages, 50 names per request; an entry locked from the GitHub API (`<api>/repos/…`) gets `GET <api>/repos/<owner>/<repo>/security-advisories?state=published`, one page of 100 (a warning when full), without withdrawn ones. An advisory whose affected versions (Composer's `affectedVersions`, GitHub's semver `vulnerable_version_range`, both read as Composer constraints) match the locked version is a finding `advisory`, level error; one without ranges or with a range skillcask cannot read counts as affecting it. An entry locked at a commit (`ref`) has no version to match: an advisory published after the commit's release time counts, one published before is taken as fixed. A Composer package whose newest version is `abandoned` is a finding `abandoned`, level warning, naming the replacement only when it is a valid package name. Both are listed under each skill of the package and exit 1 like every finding. A source that cannot be read is a warning, exit 1 and a SARIF tool execution notification; an unreadable Composer root counts once and skips its packages. Packages whose source names no advisory API, plain git entries (D30), GitHub entries while `github` is off, and sources the policy refuses are listed as unchecked, with no request and without failing. `--json` adds `advisories`: {`unchecked`, `failed`}, `null` without the flag. Advisory text is shown with control characters escaped. | `audit` reads only the text, so a skill with a known, published flaw passed it. The registries already publish advisories for Composer packages, and GitHub for repositories, so skill authors can use the channel they know; skillcask adds no database and no service of its own. Opt-in, because the app (D35, D53) and `ui` (D41) run `audit` on every change and must stay offline; CI adds the flag. Failing on an unreadable source keeps a required check from passing by accident; a source without advisories cannot fail the run, or every private registry would. A commit cannot be matched against version ranges, and counting every advisory the repository ever published would fail it for good with no way out; the publication time is what the lock and GitHub both record. GitHub's `vulnerabilities[].package` is not compared: a skill has no ecosystem name, so a monorepo's advisories for its other packages are reported too. Code a skill bundles (`package.json`, `requirements.txt`) is left to scanners for those ecosystems (README). |
| D56 | `[policy] deny-patterns = true` (D31) also turns the invisible characters of D23 into exit 1 before anything is written; the error names both causes. One key, not a second one. The list gains variation selectors (U+FE00-FE0F, U+E0100-E01EF), U+00AD, U+034F, U+180E, U+2061-2064 and U+206A-206F; not reported are a leading byte order mark, a zero width joiner between two emoji, and one U+FE0F right after a visible character (`❤️`, `⬆️`, `1️⃣`). | Hidden Unicode is how text an agent reads differs from text a reviewer sees, so it is the same threat as a risky line; an organisation that refuses one wants the other refused too. A separate key would double the policy surface (D18 enforce lists, `SKILLCASK_*` overrides, the app's settings) for no case anyone asked for. microsoft/apm scans for hidden Unicode on every install as well. Variation selectors after an emoji are the usual ASCII-smuggling channel (one byte per selector), so a refusal that misses them would promise too much; emoji presentation needs only one U+FE0F after its base. |
| D57 | `[policy] deny-packages` lists packages refused by name: `vendor/name` or `vendor/*` (each part valid as in a package name, read as lowercase), matched case-insensitively, whatever source serves them (a GitHub entry by its `owner/repo`, a plain git entry by its key, which the project chooses, so `deny-packages` does not bind git URLs; `allow-sources` does). A D18 list key, but an enforced list is a floor: a project's or the environment's `deny-packages` must deny everything the enforced one does (in any order, `vendor/*` covering its names) and may add to it, and the project's longer list is the one that applies; one that drops an entry is exit 1. `SKILLCASK_DENY_PACKAGES` is comma-separated; `,` sets an empty list, which lifts a list that is not enforced. Checked before any request for the package (registry lookup, GitHub or git source) and on every lock entry before anything is written, in `diff` too, so dependencies and a committed lock are refused alike. | `allow-sources` trusts a source as a whole; a known-bad package on a trusted source (Packagist, GitHub) needs a name rule. microsoft/apm has `dependencies.deny` for the same reason. Matching names, not sources, keeps it one simple rule; `vendor/*` covers a compromised account. No allow-list by name: `allow-sources` plus review of the lock already decide what comes in. |

## Project files

```
skills.toml                  # manifest, committed
skills.lock                  # lock, committed, generated
.agents/skills/<name>/       # installed skill (managed: gitignored; hand-written: committed)
.claude/skills/<name>  -> ../../.agents/skills/<name>
.junie/skills/<name>   -> ../../.agents/skills/<name>
.skills/<name>/              # project skill, committed; .agents/skills/<name> links to it
.gitignore                   # managed block
```

### `skills.toml`

```toml
[repositories]
# packagist = { type = "composer", url = "https://repo.packagist.org" }  # implicit default
acme = { type = "composer", url = "https://git.example.com/api/v4/group/42/-/packages/composer/packages.json" }
# own = { url = "…", min-release-age = "0" }   # overrides policy.min-release-age here (D15)

[skills]
"netresearch/agent-jira-skill" = "^2.0"
"acme/agents-md" = { version = "^1.0", repository = "acme" }
"acme/review" = { version = "1.4.2", repository = "acme", skills = ["review"] }

[agents]
targets = ["claude"]                            # default (D29); .agents/skills is always the store
local = ".skills"                                 # default; project skills

[policy]
min-release-age = "3d"     # default; "0" disables
allow-ranges = true        # false: every version must be exact (x.y.z)
packagist = true           # false: drop the implicit Packagist repository
```

- A skill entry without `repository` is looked up in declared repositories in order, then
  Packagist. The repository that served it is written to the lock. Once locked, `install`, `update` and `add` look
  for it only in that repository; if it is gone from there, they fail rather than take a package
  with the same name from another repository. Setting `repository` moves it on purpose.
- `skills = [...]` selects skills from a package that ships several; default: all.
- `policy.allow-ranges = false` is for organisations whose standard forbids ranges even with a
  lock; `add` then writes the resolved exact version.
- GitHub entries: `{ github = true, version = "^1.3" }` resolves over version tags;
  `{ github = true, ref = "main" }` follows a branch, tag or commit; neither means the default
  branch (`HEAD`). The key is `owner/repo`, lowercase. `repository` cannot be combined with
  `github`. With `allow-ranges = false`, `ref` must be a full commit sha.

### `skills.lock`

```toml
version = 1

[[package]]
name = "acme/agents-md"
constraint = "^1.0"
version = "1.0.2"
repository = "https://git.example.com/api/v4/group/42/-/packages/composer/packages.json"
dist = { type = "zip", url = "https://…/agents-md-1.0.2.zip", reference = "9f2c1e…" }
dist-sha256 = "…"
released = 2026-10-01T09:12:00Z
skills = [{ name = "agents-md", path = "", tree-sha256 = "…" }]
```

- `reference`: `dist.reference`, else `source.reference` from the metadata (a commit sha for
  VCS-backed packages).
- `dist-sha256`: computed by skillcask at lock time. Composer's `dist.shasum` is used only as an
  extra check when present (it is empty for GitHub zipballs).
- `tree-sha256`: hash of the installed skill directory. Definition: for every regular file, sorted
  by relative path with `/` separators, the line `<path>\0<mode>\0<sha256 of content>\n`, where
  mode is `644` or `755`; the hash of the concatenation. No symlink is ever written: a
  relative symlink to a regular file inside the same skill (`CLAUDE.md -> AGENTS.md`) is installed
  and hashed as a copy of that file; any other symlink inside a skill, devices and empty
  directories are rejected at install. Symlinks outside the installed skill directories are
  ignored.
- `ref` (GitHub entries only): `true` when `constraint` is a branch, tag or commit (`ref =` in the
  manifest), `false` when it is a version constraint over tags.
- `selected`: the entry's `skills = [...]`, sorted; absent when the entry installs all skills.
- `ref` and `selected` are written only when they apply, so other entries render as before.
  Locks written before these keys existed still parse and install: an absent `selected` means
  all skills unless the manifest entry has `skills = [...]` (then the locked skill names are
  compared, as before), and an absent `ref` is not compared. A non-frozen `install` adds the
  missing keys; `--frozen` never fails only because they are missing.
- Parsing rejects (exit 1, `skills.lock: invalid …`) a hash that is not 64 lowercase hex digits,
  a dist URL that is not `https://`, a dist type other than `zip`, a package listed twice, and a
  `from` equal to the skill's `name`.
- Written atomically: a temp file in the same directory, then a rename (`skills.toml` too).
- Entries sorted by `name`; no timestamps other than `released`, so parallel branches merge.

## Package format

A skill package is a Composer package with `"type": "ai-agent-skill"`, or any package with
`extra.ai-agent-skill`:

```json
{ "name": "acme/agents-md", "type": "ai-agent-skill", "extra": { "ai-agent-skill": "SKILL.md" } }
```

`extra.ai-agent-skill` is a path to a `SKILL.md` (the skill is its directory) or a list of such
paths for packages with several skills. Missing: `SKILL.md` at the package root. The skill name
is the frontmatter `name`; it must match `[a-z0-9][a-z0-9-]*` and is the directory name under
`.agents/skills/`. Two packages providing the same skill name is an error naming both.

## Resolution

1. Read `packages.json` of each repository (a URL ending in `.json` or carrying a query string is
   used as given, otherwise `/packages.json` is appended). Take the package from the inline
   `packages` map when it is there (Composer v1: version → metadata), else follow `metadata-url`
   (`/p2/%package%.json`). Expand Composer's minified format (`"minified": "composer/2.0"`: each version inherits
   fields from the previous one; `"__unset"` removes a field).
2. Keep versions whose type is `ai-agent-skill` or that carry `extra.ai-agent-skill`.
3. Stability: stable only (`version_normalized` without a stability suffix) unless the
   constraint names one (`1.0.0-beta2`, `@beta`). `dev-*` branches are never resolved.
4. Constraints follow Composer semantics, not npm's: `^1.2` = `>=1.2.0 <2.0.0`, `^0.3` =
   `>=0.3.0 <0.4.0`, `~1.2` = `>=1.2 <2.0`, `~1.2.3` = `>=1.2.3 <1.3.0`, `1.2.*`, `>=`, `<`, `!=`,
   AND by space or comma, OR by `||`.
5. Cooldown: drop versions whose `time` is newer than `now - min-release-age`. A version without
   `time` is kept with a warning (GitLab metadata may omit it). If the cooldown removes every
   match, the error names the newest version and when it becomes eligible.
6. Pick the highest remaining version.

### GitHub sources

1. `version`: list tags (`GET /repos/{o}/{r}/tags`, up to 1,000), keep those that parse as
   versions, apply the constraint. Release time is the tag's commit date, or the publication
   time of its GitHub release when that is later (`GET /repos/{o}/{r}/releases`, first 100),
   fetched newest first until one passes the cooldown. Tags are read once per run.
2. `ref`: `GET /repos/{o}/{r}/commits/{ref}`. For a branch (`HEAD` is the default branch), the
   Activity API (`GET /repos/{o}/{r}/activity?ref={branch}`, first 100) gives push times: the
   eligible commit is the head after the newest push before the cutoff, or the head before the
   oldest listed push when all of them are newer and fewer than 100 are listed. A tag, or a
   branch without listed activity, falls back to commit dates: if the commit is newer than the
   cooldown and the ref is not a sha, take the newest commit on the ref before the cutoff
   (`commits?sha={ref}&until={cutoff}`) and say so.
3. Lock: `repository` = `<api>/repos/{o}/{r}`, `dist.url` = `<api>/repos/{o}/{r}/zipball/{sha}`,
   `reference` = the sha, `version` = the tag, or the first 12 characters of the sha for a ref.
4. Skills: every `SKILL.md` in the archive that is not inside another skill. Name: frontmatter
   `name` if valid, else the directory name (the repository name for a root `SKILL.md`); neither
   valid skips it with a warning.

Commit dates are set by the committer, so where they are the only time (a tag without a release, a
ref without listed pushes, a pinned sha) the cooldown is weaker than with registry release times;
the pinned sha and hashes still make `install` reproduce exactly what was reviewed. GitHub
zipballs are not guaranteed byte-stable; if GitHub regenerates one, `install` stops with a hash
mismatch (exit 4) rather than installing unverified content.

### Plain git sources

As GitHub sources, with these differences (D30): refs come from
`GET <url>/info/refs?service=git-upload-pack`, a commit from `POST <url>/git-upload-pack`
(`want <sha>`, `deepen 1`); tags peel to their commit; `HEAD` is the default branch. The lock's
`repository` and `dist.url` are the repository URL, `reference` the sha, `version` the tag or the
first 12 characters of the sha. `allow-sources` matches the URL by prefix.

## Commands

| Command | Behaviour |
|---|---|
| `init` | Create `skills.toml` with defaults. |
| `add github:<owner/repo>[/skill][@version-or-ref]` | GitHub entry; `/skill` adds to `skills = [...]`. `@x` is a version constraint when it parses as one, else a ref. Without `@`: version tags if the repository has any (`^<major.minor>`), else the default branch. |
| `add git:<https-url>[@version-or-ref]` | Plain git entry named after the URL's last two parts (D30); `@x` as for GitHub. |
| `add <vendor/name>[@constraint] [--repository r]` | Resolve first (typo or no match leaves files untouched), write manifest and lock, install. No constraint: the existing entry's constraint, else `^<major.minor>` of the resolved version, or the exact `x.y.z` with `allow-ranges = false`. |
| `remove <vendor/name>…` | Drop from manifest and lock; remove installed directories, links and gitignore lines. |
| `install [--frozen]` | Install exactly the lock: download dist, verify `dist-sha256`, unpack to a temp dir, verify every `tree-sha256`, move into place, link, rewrite the gitignore block. Entries in the manifest that do not match the lock (missing, or a changed constraint, repository, GitHub mode, `skills` selection or `rename`) are resolved and locked; with `--frozen` (implied when `CI` is set) that is exit 1 instead. When only `skills` or `rename` changed, or the locked version still satisfies a changed constraint, the locked version is kept. Already-installed skills whose tree hash matches are skipped. |
| `update [vendor/name…] [--diff]` | Re-resolve within constraints (cooldown applies), rewrite the lock, install; `--diff` prints each changed or added package's diff before writing the lock, without asking (D27). Entries not locked yet are resolved too; other drifted entries get a warning. |
| `outdated [--strict]` | Per package: locked, newest within constraint, newest overall, eligible date under cooldown. `--strict`: exit 1 when `update` would lock a newer version (D25). |
| `diff [pkg] [--to <constraint>]` | Unified diff of skill files from the locked version to the one `update` would lock (D27). |
| `info <vendor/name[@c]\|github:owner/repo[@v]\|skill>` | Skills, versions and metadata of a package, or which package and entry install a skill (D26). |
| `status` | Manifest vs lock (every reason `install --frozen` checks, and a skill name provided by two packages) vs installed (hash) per skill. Exit 1 on any mismatch. |
| `audit [--json\|--sarif] [--advisories]` | What installed and project skills reach, and modified files, risky lines and invisible characters (D34); with `--advisories` also published security advisories and abandoned packages (D55). Exit 1 on any finding. |
| `doctor [--fix]` | Broken or committed managed links, stale gitignore block, modified installed skills (tree hash). A person also sees each check that passed. `--fix` repairs without downloading. |
| `config [key [value…]] [--unset] [--json]`, `config edit` | Read or change settings of `skills.toml`, with `--global` of `config.toml` (D48). |
| `search <query>` | Packagist search API filtered by `type=ai-agent-skill`; for other repositories, a substring match over the names in `available-packages`, inline `packages` or `provider-includes` (GitLab), matches after the vendor first, then the metadata of the inline matches and of up to 30 others to keep skill packages and show their description (D49). A failing repository is a warning unless all fail. |
| `self-check [--json]` | Whether a newer skillcask is released; one anonymous request for the tap's cask file, only when run (D51). |
| `<other>` | Runs `skillcask-<other>` from `PATH` with the remaining arguments and exits with its code (git/cargo-style plugins). Only executables the user installed; packages never provide them. Migrations from other manifest formats live in plugins, not in the core. |
| `publish` | See Publishing. |

Exit codes: 0 ok; 1 manifest/lock/status problems or drift under `--frozen`; 2 authentication;
3 network or HTTP error; 4 hash mismatch; 5 IO or archive error.

## Installing and linking

- Store: `.agents/skills/<name>/`, replaced atomically (unpack to a sibling temp dir, verify,
  rename). Temp dirs carry the pid of their run, which holds a lock on
  `.agents/skills/.skillcask-run-<pid>` while it lives and removes on exit (D45); `install` removes
  the ones whose run is gone (without a run lock, from older versions: those older than an hour).
- Each target in `agents.targets` gets `<target>/<name>` → relative path to the store.
- Managed skills (present in the lock) and their links are listed in a marked `.gitignore` block,
  regenerated on every `install`, `update`, `remove`. A managed link found in the git index is
  removed from it (`git rm --cached`), never from the working tree.
- Hand-written skills: any directory under `.agents/skills/` with a `SKILL.md` and no lock entry
  is linked into the targets too, and those links are committed (their target is tracked, so they
  resolve in every clone). A name that is both hand-written and locked is an error.
- Project skills: every `<local>/<name>/SKILL.md` (`[agents] local`, default `.skills`) gets
  `.agents/skills/<name>` → `../../<local>/<name>`, then the usual target links. All of them are
  committed. When the project skill is deleted, its links are removed on the next `install`. A
  name that is both a project skill and locked is an error.
- A name clash inside the project (two packages, a project skill, a foreign directory) is an
  error that names the `rename = { … }` fix; in a terminal `add`, `install` and `update` offer it.
  A personal skill with the same name (`~/.claude/skills/<name>`) is a warning, unless its content
  is the same as the project's (D45). See D13.
- Windows without symlink permission: copy instead of link, and list the copies in the managed
  block.

## Authentication

Sources, first match per host: `COMPOSER_AUTH` (JSON), `./auth.json`, `$COMPOSER_HOME/auth.json`
(default `~/.composer/auth.json` or `~/.config/composer/auth.json`). Supported keys:
`http-basic`, `bearer`, `gitlab-token`, `gitlab-oauth`, `github-oauth` (a `github.com` token is
also used for `api.github.com`). `GITHUB_TOKEN` or `GH_TOKEN` is the last fallback for the host
of the GitHub API the user or the runner names (`SKILLCASK_GITHUB_API`, else GitHub Actions'
`GITHUB_API_URL`, else `https://api.github.com`), never a `github` url from `skills.toml` (D43);
such a host needs `github-oauth` in `auth.json` or `skillcask auth set <host> --username oauth2`.
Then git's credential helper (D17): `git credential fill` once per remaining host, never
interactive (no terminal prompt, no askpass, `GCM_INTERACTIVE=never`), off with
`SKILLCASK_GIT_CREDENTIALS=0`. The username picks the
header: `PRIVATE-TOKEN` the GitLab header, `oauth2` a Bearer token, any other HTTP Basic.
`skillcask auth set <host> [--username U]` stores a token (asked by git without echo, or read from
a pipe) and `auth remove` deletes only that username's entry. A GitLab CI job reads the registry with
`http-basic` user `gitlab-ci-token`, password `$CI_JOB_TOKEN`. Tokens are never printed, including
in `--verbose` URLs.

## Security

- HTTPS only; `http://` repositories and dist URLs are rejected. TLS through the platform
  verifier (system trust store), so corporate CAs work without flags; no option to disable
  verification.
- Archives: reject absolute paths, `..`, symlinks leaving their skill, hard links and devices; limits on download
  size (50 MiB), unpacked size (100 MiB) and file count (5,000), overridable per command.
- Archive names must work on every OS: no Windows-reserved names (`CON`, `PRN`, `AUX`, `NUL`,
  `COM1`-`COM9`, `LPT1`-`LPT9`, also with an extension), no trailing dot or space, no
  `<>:"|?*\` or control characters, and no two paths that are one name on a case-insensitive
  or Unicode-normalising file system (`README.md` and `readme.md`, `café` composed and
  decomposed). Such entries are not extracted. A selected skill that contains one fails with
  the same error on every OS; outside the selected skills they are skipped, so a stray file in
  a repository does not block its skills. Duplicate entries and mismatched zip headers fail the
  whole archive, and the limits count every entry.
- No package code runs at any point.
- Release artefacts: checksums and build provenance attestations; `skillcask --version` prints
  the commit.

## Publishing

**One repository per skill**: a `composer.json` with the convention above and semver tags.
Packagist reads public repositories; GitLab publishes a tag to its Composer registry
(`POST /projects/:id/packages/composer`). skillcask has no part in it.

**Monorepo**: `skillcask publish --vendor acme --base-url <url> --out <dir> [paths…]` finds
every `SKILL.md` with frontmatter `name` and `version`, and writes a static Composer repository:

```
<dir>/packages.json            # metadata-url: <base-url>/p2/%package%.json, available-packages
<dir>/p2/acme/<name>.json      # all published versions, not minified
<dir>/dist/acme/<name>/<version>.zip
```

- Package name: frontmatter `package:` when set, else `<vendor>/<name>`. The directory a skill sits
  in plays no part, so nested folders (`skills/team/lang/<name>`) give `<vendor>/<name>` too. One
  package comes from one directory: two `SKILL.md` files with the same package name are an error,
  fixed with `package:` in one of them.
- Zips are deterministic (sorted entries, fixed mtime, fixed permissions), so the same tree gives
  the same `shasum`, which `publish` writes into the metadata.
- Versions are immutable: `--out` may hold a previous run; an existing version with a different
  hash is an error, an identical one is kept. Without its zip in `--out`, a version is identical
  when its tree matches `extra.ai-agent-skill-tree` (D14); versions published by an older skillcask get
  that key on the first run whose zip still matches.
- `time` is the publish time of the version, set once, truncated to the second.
- `--dist-url <template>` sets the zip URL of new versions with `{vendor}`, `{name}` and
  `{version}`; default `<base-url>/dist/{vendor}/{name}/{version}.zip`. Zips are written to
  `dist/` either way; uploading them to the template URL is the publisher's job.
- `--inline` (D12) writes all packages into `packages.json` as `packages.<name>.<version>` and no
  `p2/`; `--base-url` is then optional when `--dist-url` is given. Earlier versions are read from
  either layout, so switching keeps them.

**Private hosting on GitLab** (monorepo): CI runs `publish --inline` with a Generic Package
Registry `--dist-url` (`.../packages/generic/{vendor}-{name}/{version}/{name}-{version}.zip`),
uploads new zips, and commits `packages.json` to the repository, which also keeps the state the
next run needs. Clients use the raw files API URL
(`.../repository/files/<path-encoded>/raw?ref=<branch>`) as the repository `url`; a
`gitlab-token` (sent as `PRIVATE-TOKEN`) for the host covers both requests.

## Testing

- Unit: constraint parser (table of Composer's own test cases for `^`, `~`, `*`, stability),
  minified metadata expansion, tree hash, lock round-trip, gitignore block rewrite.
- Integration: a local HTTPS server (test CA) serving a fixture Composer repository, covering
  install, frozen drift, hash mismatch (exit 4), cooldown, auth (`http-basic`, `bearer`),
  archive attacks (zip slip, symlink, size limit), collisions, Windows copy mode (on the Windows
  runner).
- `publish` → `install` round trip against the generated static repository, in both layouts.
- End to end against Packagist with `netresearch/agent-jira-skill`, `#[ignore]` by default.

## Distribution

GitHub repository `skillcask`, also a GitHub Action (`action.yml`, D33); releases via `cargo-dist` for macOS (arm64, x86_64), Linux
(x86_64, arm64, musl) and Windows; Homebrew tap; `cargo install skillcask`; checksums and GitHub
artefact attestations. The crate name `skillcask` was free on crates.io on 2026-10-19.

## Acceptance

- `skillcask add netresearch/agent-jira-skill` in an empty git repository creates `skills.toml`,
  `skills.lock`, `.agents/skills/<name>/`, links in `.claude/skills` and `.junie/skills`, and a
  gitignore block; a fresh clone plus `skillcask install --frozen` reproduces the same tree hash.
- Changing one byte of an installed skill makes `status` exit 1; tampering with the served zip
  makes `install` exit 4.
- With `CI=true`, a manifest entry missing from the lock makes `install` exit 1 without writing
  anything.
- A version published 1 hour ago is not selected by `add` with the default policy, and the error
  says when it becomes eligible.
- `publish` on a monorepo with three skills produces a repository that `install` consumes, and a
  second `publish` of unchanged skills changes no file.

## Open questions

1. ~~Private static repository hosting for monorepos.~~ Decided in D12: inline `packages.json`
   in git, zips in the Generic Package Registry. Rejected: GitLab's Composer registry (one package
   per project), GitLab Pages (cookie auth, a CLI cannot authenticate), `p2/` in the Generic
   Package Registry (no `/` in file names), an object store behind a token proxy (new
   infrastructure).
2. ~~Whether `search` should query several Composer repositories at once or only Packagist.~~ It
   queries all of them; see `search` above.
