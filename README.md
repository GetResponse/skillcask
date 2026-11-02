# skillcask

A lockfile-first package manager for AI agent skills: directories with a `SKILL.md`, read by
Claude Code, Codex, Junie and others.

skillcask installs skills the way Cargo or Composer install libraries. It reads a manifest with
version constraints and commits a lock with content hashes. In CI it does frozen installs that
fail on drift, and it links every skill into each agent's skill directory. It ships as a single
static binary with no runtime, so it works in a repository in any language.

Skills come from Composer repositories or straight from GitHub. Packagist serves public skill
packages; GitLab's Composer registry, Satis, Private Packagist or the static repository built by
`skillcask publish` serve private ones. Any GitHub repository with `SKILL.md` files works too,
which covers most of what [skills.sh](https://skills.sh) lists. skillcask does not need PHP,
Composer or Node.

## Install

**macOS, Linux**

```sh
brew install puniserv/tap/skillcask
# or, without Homebrew:
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/puniserv/skillcask/releases/latest/download/skillcask-installer.sh | sh
```

**Windows (PowerShell)**

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://github.com/puniserv/skillcask/releases/latest/download/skillcask-installer.ps1 | iex"
```

The two installer scripts download the binary for your platform from the latest release and put
it in `~/.cargo/bin` (`%USERPROFILE%\.cargo\bin` on Windows).

**Desktop app (macOS 14+ only for now)**

```sh
brew install puniserv/tap/skillcask puniserv/tap/skillcask-app
skillcask app                   # or open Skillcask from Applications
```

Install with the full names: Homebrew loads a third-party tap's cask only when it is named in full
(or listed by `brew trust`); after that, `brew upgrade` takes the short name.

Without Homebrew:

```sh
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/puniserv/skillcask/releases/latest/download/skillcask-app-installer.sh | sh
```

The installer downloads `Skillcask-X.Y.Z-macos-universal.zip` (signed and notarized, with its own
CLI inside) from the latest release, checks its sha256 and Gatekeeper's verdict, and moves the app
to `/Applications`; an earlier copy goes to the Trash. It leaves a Homebrew install alone.
`SKILLCASK_VERSION=X.Y.Z` picks a release, `SKILLCASK_APP_DIR` another folder.

Linux and Windows have the terminal UI, `skillcask ui`. More in [macOS app](#macos-app).

**npm, bun**

```sh
npm install -g skillcask      # global
bun add -g skillcask          # global, bun
npx skillcask install --frozen
bunx skillcask install --frozen
```

The npm package is a thin wrapper that downloads the release binary for your platform from
GitHub. It does not check a checksum itself; where that matters, use Homebrew or a release
archive and verify it.

**Cargo**

```sh
cargo install --locked skillcask
```

**Release archives** for macOS, Linux and Windows are on the
[releases page](https://github.com/puniserv/skillcask/releases), with sha256 checksums and GitHub
build provenance attestations:

```sh
gh attestation verify skillcask-x86_64-unknown-linux-gnu.tar.xz -R puniserv/skillcask
```

**GitHub Actions**

```yaml
permissions:
  contents: read
  attestations: read   # for the provenance check
steps:
  - uses: actions/checkout@<sha>
  - uses: puniserv/skillcask@<commit sha of a release tag>   # vX.Y.Z
    with:
      version: X.Y.Z               # needed when the action is pinned to a sha, not a tag
      args: install --frozen       # default
      # working-directory: .
      # verify-attestation: "true" # default
```

The action downloads the release archive for the runner (Linux x64 and arm64, macOS, Windows
x64), checks its sha256 and its build provenance attestation, puts `skillcask` on `PATH` and runs
it with `args`. It runs no other action. Used at a tag (`@vX.Y.Z`) it takes the version from the
tag.

### Update

`skillcask self-update` reruns the release's installer when `skillcask-installer.sh` installed
this binary (Linux, macOS); for any other install it prints the one command to run and exits 1.
`SKILLCASK_SELF_UPDATE=0` makes it print the installer command too. By hand:

```sh
brew update && brew upgrade skillcask skillcask-app    # Homebrew (skillcask alone without the app)
npm install -g skillcask@latest                        # npm (bun: bun add -g skillcask@latest)
cargo install --locked skillcask                       # Cargo
```

The installer scripts (`skillcask-installer.sh`, `skillcask-installer.ps1`,
`skillcask-app-installer.sh`) install the latest release when run again; the app's installer moves
the earlier copy to the Trash. The app's own CLI updates with the app; Homebrew updates the app and
the CLI on your `PATH` separately, which is why `brew upgrade` names both. For the GitHub Action,
bump the pinned commit and `version`. `skillcask --version` prints what you have.

## Use

```sh
skillcask add netresearch/agent-jira-skill   # resolve, write skills.toml + skills.lock, install
skillcask add github:mattpocock/skills/tdd   # one skill from a GitHub repository
skillcask install --frozen                   # CI: install exactly the lock or exit non-zero
skillcask status                             # manifest vs lock vs installed files
```

`add` creates:

```
skills.toml                  # manifest, commit it
skills.lock                  # lock, commit it
.agents/skills/<name>/       # installed skill (gitignored)
.agents/skills/.skillcask-installed  # what this machine installed (gitignored)
.claude/skills/<name>  -> ../../.agents/skills/<name>
.gitignore                   # managed block
```

Project skills live in `.skills/<name>/SKILL.md` (`[agents] local`). skillcask links each one
into the store (`.agents/skills/<name> -> ../../.skills/<name>`) and from there into every agent
directory. These links are committed, so they work in every clone. A directory written by hand
straight into `.agents/skills/` is linked the same way. A project skill with the same name as a
locked one is an error. When a skill with the same name exists in your home (`~/.claude/skills`,
`~/.agents/skills`, …), `install` and `doctor` print a warning: Claude Code runs the personal one,
Codex lists both.

### skills.toml

```toml
[repositories]
acme = { type = "composer", url = "https://git.example.com/api/v4/group/42/-/packages/composer/packages.json" }
# A repository you review yourself can skip the cooldown; the others keep it.
own = { url = "https://git.example.com/own/packages.json", min-release-age = "0" }
# Default sources, written by `init`; `= false` turns one off. Packagist is always searched last.
packagist = { url = "https://repo.packagist.org" }
github = { type = "github", url = "https://api.github.com" }   # GitHub Enterprise: its API URL

[skills]
"netresearch/agent-jira-skill" = "^3.34"
"acme/agents-md" = { version = "^1.0", repository = "acme" }
"acme/review" = { version = "1.4.2", repository = "acme", skills = ["review"] }
"mattpocock/skills" = { github = true, version = "^1.3", skills = ["tdd", "code-review"], rename = { code-review = "mp-code-review" } }
"anthropics/skills" = { github = true, skills = ["pdf"] }      # default branch

[agents]
targets = ["claude", "kiro"]   # agent names or paths with a "/"; default: config.toml, else ["claude"]
local = ".skills"        # project skills

[policy]
min-release-age = "3d"   # cooldown for add/update; "0" disables
allow-ranges = true      # false: every version must be exact
packagist = true         # false: drop the implicit Packagist repository
github-requires = false  # true: dependencies may come from GitHub or git URLs
allow-sources = ["acme", "own", "packagist", "github"]   # only these sources; default: all
deny-patterns = false    # true: risky patterns in new skill text fail instead of warning
```

### Agents

Most agents read `.agents/skills` themselves (Codex, Copilot, Cursor, Gemini CLI, OpenCode, Amp,
Junie, Devin/Windsurf, Roo Code, Cline, Goose, Factory, Mistral Vibe), so they need no link.
`[agents] targets` lists the agents that need one, by name, or any directory as a path with a `/`:

| Name | Project | Home (`--global`) |
|---|---|---|
| `claude` | `.claude/skills` | `~/.claude/skills` |
| `kiro` | `.kiro/skills` | `~/.kiro/skills` |
| `junie` | store | `~/.junie/skills` |
| `codex`, `copilot`, `cursor`, `gemini`, `opencode`, `amp`, `devin`, `roo`, `cline`, `goose`, `factory`, `vibe` | store | store |

Set the list once in `config.toml` next to the global manifest; a `skills.toml` that sets
`targets` replaces it. Manifests from before 0.6.0 carry an explicit list: delete the line to
follow `config.toml`.

```toml
# ~/.config/skillcask/config.toml
[agents]
targets = ["claude", "kiro"]

[search]
skills-sh = true   # search also asks skills.sh (it receives the query); written by search --remember or skillcask -g config search.skills-sh true
```

When a target is dropped, the next `install` removes the links skillcask made there; `doctor`
reports them. `status` prints the targets, where they came from and the directories they link.

Constraints follow Composer semantics: `^0.3` means `>=0.3.0 <0.4.0`, `~1.2` means
`>=1.2 <2.0`, and pre-releases are only selected when the constraint names a stability
(`^1.0@beta`).

### Allowed sources and policy for every project

`allow-sources` lists the only places skills may come from: repository names, `packagist`,
`github`, or `https://` URL prefixes (`https://api.github.com/repos/acme/` allows one GitHub
organisation). Other repositories get no request, and `install` refuses a lock entry from them,
also with `--frozen`, so a committed lock cannot bring them back. Dependencies follow the same
rule.

Policy can also come from `config.toml` next to the global manifest (`~/.config/skillcask`) and
from the environment. The first layer that sets a key wins:

1. `SKILLCASK_ALLOW_SOURCES`, `SKILLCASK_MIN_RELEASE_AGE`, `SKILLCASK_ALLOW_RANGES`,
   `SKILLCASK_PACKAGIST`, `SKILLCASK_GITHUB_REQUIRES`, `SKILLCASK_DENY_PATTERNS` (overriding an
   enforced key prints a warning);
2. keys `config.toml` lists in `enforce`: a project that sets them otherwise fails;
3. `[policy]` in `skills.toml`;
4. the other keys of `config.toml`, as defaults.

```toml
# ~/.config/skillcask/config.toml: only the company registry and GitHub, in every project
[policy]
allow-sources = ["https://gitlab.example.com/", "github"]
enforce = ["allow-sources"]
```

An enforced `min-release-age` also applies to a repository's own `min-release-age`: a project
may only make it longer. Exceptions, by URL prefix, stay in `config.toml`:

```toml
[policy]
min-release-age = "3d"
enforce = ["min-release-age"]

[policy.repository-min-release-age]
"https://gitlab.example.com/" = "0"   # internal skills, reviewed in merge requests
```

`config.toml` and the environment take URL prefixes, not repository names, since a name means
whatever a project calls it. `skillcask status` prints each key that is set and where it came
from.

### Dependencies

A skill that needs other skills lists them in its `SKILL.md`:

```yaml
---
name: gitlab-branch-mr
version: 1.2.0
requires:
  acme/security-review: ^1.0
  github:mattpocock/skills/pr: main
  "git:https://git.example.com/team/skills.git#review": ^2.0
---
```

`add`, `install` and `update` resolve, lock and install them like your own entries: same
cooldown, same hashes, one version per package (the highest one every requirer accepts). They
stay out of `skills.toml`; the lock records each package's `requires` and switches to
`version = 2`. A dependency is looked up only in your repositories, in order, then Packagist;
a `github:` or `git:<url>[#skill]` one needs `github-requires = true`. `remove` drops dependencies nobody needs any
more, and `status` shows them as `via <requirer>`.

### Name conflicts

Skills have no namespaces: an agent knows a skill by its name. Two skills with the same name in
one project are an error. Install one of them under another name with `rename`:

```toml
"mattpocock/skills" = { github = true, rename = { code-review = "mp-code-review" } }
```

skillcask then installs `.agents/skills/mp-code-review` and changes the `name:` line in its
`SKILL.md`; the lock records the original name and the hash of the renamed copy. Nothing else in
the skill changes, so text that mentions the old name (`/code-review`) stays as it is.
`add`, `install` and `update` offer the rename when they hit a conflict in a terminal.

### Personal skills (`--global`)

`skillcask --global` (`-g`) manages skills for your user instead of a project, with the same
manifest, lock and verification:

```sh
skillcask -g add github:mattpocock/skills/grill-me
skillcask -g install --frozen    # e.g. from a dotfiles repository
```

- `skills.toml`, `skills.lock` and an optional `auth.json` live in `~/.config/skillcask`
  (`$XDG_CONFIG_HOME/skillcask`; `SKILLCASK_HOME` overrides both). Keep them in your dotfiles.
- Skills go to `~/.agents/skills` (read by most agents), with links in `~/.claude/skills`
  (`[agents] targets`, see Agents). Links are absolute, so a symlinked
  `~/.claude` works. `[agents] local` does not apply.
- Personal skills you wrote by hand stay where they are and are not linked anywhere. `status`
  lists them, and copies other tools put in a target, as `not managed`; `status --json` names the
  source `npx skills` recorded for one. `skillcask -g add --adopt <source>` moves such a skill to
  `~/.config/skillcask/adopted/` and installs the package's skill of the same name in its place.
- The list of managed paths is `~/.agents/skills/.skillcask-installed`, local to the machine;
  nothing touches git.

### Commands

Every command except `publish`, `validate` and `projects` takes `-g, --global`.

| Command | |
|---|---|
| `init` | Create `skills.toml`. |
| `add <vendor/name>[@constraint] [--repository r]` | Resolve, lock and install. |
| `add github:<owner/repo>[/skill][@version-or-ref]` | The same from a GitHub repository, see below. |
| `add git:<https-url>[@version-or-ref]` | The same from any git repository over HTTPS, see below. |
| `remove <vendor/name>…` | Drop from manifest and lock; delete files, links and gitignore lines. |
| `install [--frozen]` | Install the lock. `--frozen` (implied by `CI`) fails when the lock is out of date. |
| `update [vendor/name…] [--diff]` | Re-resolve within constraints. `--diff` prints what changes in each updated or added package; it does not ask before installing. |
| `outdated [--strict]` | Newer versions, when cooled-down ones become eligible, and GitHub or git tags moved since they were locked. `--strict` exits 1 when `update` would lock a newer version. |
| `diff [vendor/name] [--to constraint\|--from old.lock]` | Unified diff of skill files from the locked version to the one `update` would lock, or from an older lock to `skills.lock`, see below. |
| `info <vendor/name[@constraint]\|github:owner/repo\|git:url\|skill>` | A package's skills, versions, description, license and requirements, or which package installs a skill. |
| `status` | Exit 1 when manifest, lock or installed files disagree. Also lists the repositories in use (name, type, URL without credentials) and whether `allow-sources` admits each. |
| `doctor [--fix]` | Broken or committed links, stale gitignore block, modified skills; lists each check it ran. |
| `audit [--json\|--sarif]` | What each installed skill reaches (commands, hosts, paths, env vars, scripts) and its findings: modified files, risky lines, invisible characters. Exit 1 on any finding. |
| `config [key [value…]] [--unset] [--json]` | Settings with where each comes from: `[policy]` and `[agents] targets` of `skills.toml`, or with `-g` of `config.toml` (also `policy.enforce` and `search.skills-sh`). `config policy.min-release-age 5d` sets a key, `--unset` removes it, each checked before the file is written; `config edit` opens the file in `$VISUAL`/`$EDITOR` and checks it afterwards. |
| `search [query] [--skills-sh\|--no-skills-sh [--remember]]` | Packagist (`type=ai-agent-skill`) and skill packages of the other repositories, GitLab included; with skills.sh on, also the GitHub skills it lists, as `github:owner/repo/skill` with their install count. skills.sh is off until you turn it on, since it receives the query: the first search in a terminal asks once, `--remember` saves a flag's choice (no query needed), both in `config.toml`. |
| `auth set\|remove <host>` | Keep a registry token in git's credential helper (Keychain, Credential Manager, libsecret). |
| `publish --vendor v --base-url URL --out DIR [--inline] [--dist-url TPL] [paths…]` | Build a static Composer repository from a monorepo. |
| `validate [paths…]` | Check `SKILL.md` files against the Agent Skills spec, see below. |
| `projects [dirs…]` | Directories that hold `skills.toml` under the given ones (default: the current one), up to 6 levels down; hidden directories, `node_modules`, `vendor`, `target` and `Library` are skipped. |
| `ui` | A terminal UI over the commands above: skills with their state and updates, `info`, SKILL.md and `audit` per skill, add, adopt (also offered when an add hits a skill skillcask does not manage), update (diff first), remove, doctor, a filter of the list, search of the registries (and skills.sh, asked once), the repositories in use (`R`, `S` turns skills.sh on or off) and a projects picker; `g` switches between the project and `--global`. |
| `app` | Opens the macOS app (see [macOS app](#macos-app)); exits 1 when it is not installed, and on Linux and Windows. |
| `self-check [--json]` | Whether a newer skillcask is released, from the `skillcask-app` cask file of the tap; one anonymous request, only when run; writes nothing. |
| `self-update [--dry-run]` | Update skillcask: reruns the release's installer for an installer-script install (Linux, macOS), else prints the Homebrew, npm, cargo or app command and exits 1. `--dry-run` prints what would run. |
| `<other>` | Runs `skillcask-<other>` from `PATH`, like git and cargo plugins. |

`status`, `outdated`, `info`, `search`, `doctor`, `audit`, `projects`, `config` and
`self-check` take `--json`: one JSON document on one line of stdout, with the same exit code;
warnings and errors stay on stderr. Package text in it is escaped as in the terminal
(`<U+202E>`). `status --json` has `repositories`
(`[{"name", "type", "url", "allowed"}]`) and `skills-sh`; `search --json` results carry `source` (the repository
name, or `skills.sh`) and `installs`, and the document has `"skills-sh": true|false|null` (`null`:
never decided). `self-check --json` is `{"version", "latest", "newer"}` (`latest` is `null` when
the cask holds no readable version). For example `skillcask outdated --json | jq
'.packages[] | select(.within != .locked)'`.

Exit codes: 0 ok, 1 manifest/lock/status problems, 2 authentication, 3 network, 4 hash mismatch,
5 IO or archive error. `self-update` exits 1 when it updated nothing and printed the command to run;
when it runs the installer, the installer's exit code is its own.

Output is coloured in a terminal (`NO_COLOR` turns it off, `CLICOLOR_FORCE` on) and errors name
the next step on a `hint:` line. For coding agents, `--agent` or `SKILLCASK_AGENT=1` prints terse,
uncoloured, tab-separated output with only the rows that need action; it is on by itself when
`AI_AGENT` or `CLAUDECODE=1` is set, unless `SKILLCASK_AGENT=0`.

A failed connection, HTTP 429 or a 5xx response is retried twice, after 1 s and 2 s or after the
`Retry-After` seconds the server sends. A `Retry-After` above 60 s, a spent GitHub rate limit, a
timeout or a TLS error fails at once.

`add`, `update` and `outdated` warn about a package its registry marks `abandoned` and name the
replacement when there is one (and it is a valid package name). Installing from the lock does not ask the registry.

**Reviewing an update:** a skill is a prompt, so read what changes before you take it.
`skillcask diff` prints a unified diff of the skill files, from the locked version to the one
`update` would lock (newest within the constraint, past the cooldown), for every entry in
`skills.toml` with a newer version; `diff vendor/name --to 2.0.0` compares one package with
another version. A package new to the lock, such as a dependency a new version adds, is shown as
all added. Nothing is installed or written. Control characters, bidi controls and other
invisible characters in the diff are shown as `<U+XXXX>` (a carriage return too, when the line
ends change), and invisible characters in changed files are warned about. Files over 1 MiB or
10,000 lines print `Files differ (too large to show)`. `update --diff` prints the same diff
before it writes the lock, then installs without asking: run `skillcask diff` first to review
and decide. A scheduled CI job can run `skillcask outdated --strict` (exit 1 when something is to
update), then `skillcask update --diff` and open a pull request with the output.

**Reviewing a lock change:** `skillcask diff --from old.lock` prints the same diff from the
versions in another lock to those in `skills.lock`, plus the packages it drops, so a reviewer
sees the skill text a pull request brings in instead of new versions and hashes. Each new dist
is verified against `skills.lock` as `install` would, and the policy decides which repositories
may be fetched. skillcask does not run git; the job fetches the old lock:

```yaml
# GitLab CI: print the diff in the merge request pipeline
skills-diff:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes: [skills.lock]
  script:
    - git fetch --depth 1 origin "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
    - git show FETCH_HEAD:skills.lock | skillcask diff --from -
```

`--from -` reads the old lock from stdin. On GitHub the same lines run in a `pull_request` job with `$GITHUB_BASE_REF`; posting the
output as a comment is up to the CI.

**Where a skill comes from:** `skillcask info vendor/name` shows the package's skills with their
descriptions, its versions, description, license, `abandoned` and `requires`, for the locked
version or else the newest one `add` would take (`@constraint` for another); `info
github:owner/repo` lists the skills of a GitHub repository before you add it. `skillcask info
<skill>` names the package that installs an installed skill and the `skills.toml` entry, or the
chain of `requires`, that brings it in.

**Merge conflicts in `skills.lock`:** a lock with conflict markers fails with a hint. Resolve
`skills.toml`, keep either side of the lock (`git checkout --theirs skills.lock`) and run
`skillcask install`: it locks the entries from the other side that the kept lock lacks.

### Skills from GitHub and skills.sh

[skills.sh](https://skills.sh) lists skills as `owner/repo/skill`, for example
`mattpocock/skills/grill-me`. Put `github:` in front and add it:

```sh
skillcask add github:mattpocock/skills/grill-me   # one skill
skillcask add github:mattpocock/skills/tdd        # a second one from the same repository
skillcask add github:anthropics/skills            # every skill in the repository
```

All skills of one repository share one entry in `skills.toml`:

```toml
"mattpocock/skills" = { github = true, version = "^1.3", skills = ["grill-me", "tdd"] }
```

Which version you get:

- **Repository with version tags** (`v1.3.1`): `add` writes `version = "^<major.minor>"`, like
  for Composer packages, and `update` moves within it. The release time of a tag is its commit
  date.
- **Repository without tags**: the entry follows the default branch; `ref = "main"` names a
  branch, tag or commit instead. The lock pins the commit sha, so `install` keeps installing that
  commit until you run `update`.
- `@` picks explicitly: `github:owner/repo@^2.0` (version tags), `github:owner/repo@main` or
  `@<commit sha>` (ref).
- With `policy.allow-ranges = false` a branch counts as a range: `add` writes the full commit sha
  as `ref`, and a hand-written branch name is rejected.

Skills are found by their `SKILL.md` anywhere in the repository, except inside another skill.
The install name is the frontmatter `name`; when that is not a valid name (`Jira Automation`), the
directory name is used. `skills = [...]` takes these names.

GitHub allows 60 anonymous API requests per hour. `add`, `update` and `outdated` use a few per
entry; `install` from the lock uses none, it downloads the pinned archive. Set `GITHUB_TOKEN`
(GitHub Actions has one) or Composer's `"github-oauth": {"github.com": "<token>"}` in `auth.json`
for a higher limit and for private repositories. `SKILLCASK_GITHUB_API` points at GitHub
Enterprise (`https://ghe.example.com/api/v3`). `GITHUB_TOKEN` is sent only to the API the user or
the runner names: `SKILLCASK_GITHUB_API`, else GitHub Actions' `GITHUB_API_URL`, else
`api.github.com`; for an Enterprise URL set only in `skills.toml`, use
`skillcask auth set ghe.example.com --username oauth2` or `github-oauth` in `auth.json`.

skills.sh itself is not queried: its API is undocumented and may change without notice. Search
on the website, then add what you picked.

### Skills from any git repository

GitLab, Bitbucket, Azure DevOps, Gitea or a self-hosted server work without a Composer registry:

```sh
skillcask add git:https://gitlab.example.com/acme/skills.git
skillcask add git:https://gitlab.example.com/acme/skills.git@main
```

```toml
"acme/skills" = { git = "https://gitlab.example.com/acme/skills.git", version = "^1.0" }
```

Versions, `ref` and `skills = [...]` work as for GitHub; the entry is named after the last two
parts of the URL. skillcask speaks git's HTTPS protocol itself: no git binary runs, so no hook or
filter of the repository can. It fetches the one commit it needs and checks every file against
the commit's object ids. Credentials come from the same places as for registries (`auth.json`,
the credential helper, `$CI_JOB_TOKEN` in GitLab CI). Git servers keep no release or push times,
so `min-release-age` uses commit dates, which the committer sets; a branch whose newest commit is
too young falls back to an older commit when the server supports partial fetches (`filter`).

## Security

- The lock pins the version, the commit reference, the sha256 of the downloaded archive and
  the tree hash of every installed skill. `install` verifies both hashes, so what gets installed
  is what was reviewed.
- HTTPS only, verified against the system trust store, so corporate CAs work. Verification
  cannot be turned off; `SKILLCASK_CA_FILE` replaces the trust store with a PEM bundle.
- Archives with absolute paths, `..`, devices or symlinks that leave their skill are rejected.
  No symlink is ever written from a package. Size and file count are capped (`--max-download`,
  `--max-unpacked`, `--max-files`).
- File names must be valid on every OS: Windows-reserved names, `<>:"|?*\`, control characters
  and paths that collide by case or Unicode form fail a skill that contains them, and are
  skipped outside the selected skills.
- No package code runs, ever. No telemetry.
- `self-check` and the app's "Check for Updates…" send nothing but the request for the tap's cask
  file, which carries the skillcask version in its User-Agent (`skillcask/<version>`): no token,
  account, project or skill data; GitHub sees your IP address. The app checks
  daily only after you say yes. `SKILLCASK_SELF_CHECK_URL` points it at a mirror (HTTPS only).
- `self-update` sends the same request, then, for an installer-script install only, downloads that
  release's `skillcask-installer.sh` the same way (`SKILLCASK_SELF_UPDATE_URL` replaces the
  download base) and runs it with `/bin/sh`, without your `SKILLCASK_*`, `INSTALLER_*` and
  `CARGO_DIST_*` variables. The script checks the archive's sha256 with `sha256sum`, so
  `self-update` refuses to run it when `sha256sum` is not on `PATH`.
- `add` and `update` (and `install` when it resolves) warn about characters a reviewer cannot
  see in the text files of new content: bidi controls (`U+202A`-`U+202E`, `U+2066`-`U+2069`,
  `U+200E`, `U+200F`, `U+061C`), zero-width characters (`U+200B`-`U+200D`, `U+2060`, `U+FEFF`) and
  Unicode tags (`U+E0000`-`U+E007F`), as `warning: acme/x: skills/foo/SKILL.md:12: U+202E
  RIGHT-TO-LEFT OVERRIDE`, at most five per file. A leading byte order mark and a zero width
  joiner inside an emoji are not reported; right-to-left and Indic text can trigger warnings.
  Installing from the lock does not warn again.
- The same commands warn about lines that usually mean harm, as `warning: acme/x:
  skills/foo/SKILL.md:12: downloads code into a shell`, at most five per file:

  | Warning | Matches (case-insensitive) |
  |---|---|
  | downloads code into a shell | `curl`, `wget`, `irm`, `iwr`, `Invoke-WebRequest` or `Invoke-RestMethod` piped (`\|`) into `sh`, `bash`, `zsh`, `dash`, `iex`, `Invoke-Expression`, `python`, `perl`, `ruby` or `node`, also after `sudo` |
  | decodes base64 and runs it | `base64 -d`, `base64 --decode`, `b64decode` or `FromBase64String` with a pipe into a shell, `eval`, `exec(` or `iex` |
  | reads SSH keys | `~/.ssh`, `$HOME/.ssh`, `id_rsa`, `id_ed25519` |
  | reads system account files | `/etc/passwd`, `/etc/shadow` |
  | tells the agent to ignore its instructions | "ignore (all) previous/prior instructions", "disregard all previous/prior" |

  Skills that teach shell setup trigger some of these legitimately, so they are warnings. With
  `deny-patterns = true` under `[policy]` (or enforced in `config.toml`) they fail the command
  with exit 1 and nothing is written.
- `skillcask audit` reviews what is installed now, every skill in `.agents/skills` and the project
  skills: the commands its shell code blocks run, the hosts of its URLs, the paths in the home
  directory or under system roots, the environment variables it reads and the files an agent could
  run. That is read from the text, so it is a hint for review, not a sandbox. It also reports a
  locked skill that differs from the lock, and every risky line and invisible character above,
  with no limit per file, and exits 1 on any of them. `--sarif` prints a SARIF 2.1.0 log for code
  scanning, e.g. in GitHub Actions:

  ```yaml
  - uses: puniserv/skillcask@v0.8.0
    with:
      args: install --frozen
  - run: skillcask audit --sarif > skills.sarif
  - uses: github/codeql-action/upload-sarif@v3
    if: always()
    with:
      sarif_file: skills.sarif
  ```
- Plain git sources pin the commit; the lock's `dist-sha256` hashes the commit's file list
  (path, mode, sha256 of the content), so it does not depend on how a server packs objects.
- `min-release-age` for GitHub sources uses times GitHub sets: release publication for tags,
  push times from the Activity API for branches. A tag without a release, or a ref GitHub lists no
  pushes for, falls back to commit dates, which the committer sets; reviewing what `add`/`update`
  change in `skills.lock` is the real check there.
- Credentials come from Composer's `auth.json` / `COMPOSER_AUTH` (`http-basic`, `bearer`,
  `gitlab-token`, `gitlab-oauth`), then from git's credential helper, and are never printed.
  `skillcask auth set git.example.com` keeps a token in the macOS Keychain, the Windows Credential
  Manager or libsecret instead of a plain-text file (the default username `PRIVATE-TOKEN` sends
  GitLab's header; `--username oauth2` a Bearer token). `SKILLCASK_GIT_CREDENTIALS=0` turns the
  helper off. In GitLab CI use `http-basic` with the
  user `gitlab-ci-token` and the password `$CI_JOB_TOKEN`.

## Publishing skills

**One repository per skill:** a `composer.json` with `"type": "ai-agent-skill"` (the
[netresearch convention](https://github.com/netresearch/composer-agent-skill-plugin)) and semver
tags. Packagist or GitLab's Composer registry picks up the tags; skillcask plays no part.

**Monorepo:** give each `SKILL.md` a `version` in its frontmatter and run

```sh
skillcask publish --vendor acme --base-url https://skills.example.com --out public skills/
```

This writes `packages.json`, `p2/acme/<name>.json` and deterministic zips under `dist/`. Published
versions are immutable, and re-running on unchanged skills changes no file. Serve the directory
over HTTPS.

Check the skills before publishing; `validate` exits 1 on any error and warns about invisible
Unicode, as `add` does:

```sh
skillcask validate skills/
```

It follows the [Agent Skills specification](https://agentskills.io/specification): `name` 1-64
lowercase letters, digits and single hyphens, equal to the directory name; `description` 1-1024
characters; `compatibility` at most 500. Without paths it searches the current directory, skipping
hidden ones; `skillcask validate .agents/skills` checks the skills installed in a project.
`publish` skips a `SKILL.md` without `name` or `version` and names it in a warning.

To retire a skill, publish a new version with `deprecated: true`, or `deprecated: vendor/name`
naming its replacement, in the frontmatter. It becomes Composer's `abandoned`, and consumers see a
warning on `add`, `update` and `outdated`.

Hosts that cannot serve `/` inside file names (GitLab's Generic Package Registry) take a single
file instead:

```sh
skillcask publish --inline --vendor acme --out composer/ skills/ \
  --dist-url 'https://git.example.com/api/v4/projects/7/packages/generic/{vendor}-{name}/{version}/{name}-{version}.zip'
```

`--inline` puts every package into `packages.json` and writes no `p2/`. Upload each
`dist/<vendor>/<name>/<version>.zip` to the URL the template gives, and commit `packages.json` to
a repository. A repository `url` with a query string is used as given, so clients can read the
file through the GitLab raw files API
(`.../repository/files/composer%2Fpackages.json/raw?ref=main`) with a `gitlab-token`.

## macOS app

`macos/` holds a SwiftUI app for macOS 14+ over the CLI (D35): open My Skills (the `-g` scope) or a
project folder, see each skill's state, updates and audit findings, read its SKILL.md and diffs,
and run `add` (also `--adopt`), `update`, `remove`, `install` and `doctor --fix`; its Settings
change every key `skillcask -g config` lists. It has no package logic of its own: it runs the
`skillcask` binary, 0.9.4 or newer, and reads its `--json` output.

Install it with Homebrew, then open it from Applications or with `skillcask app`. The cask depends
on the formula; name both, since Homebrew loads from a third-party tap only what it was asked for
or what `brew trust` lists:

```sh
brew install puniserv/tap/skillcask puniserv/tap/skillcask-app
```

Every release also has `Skillcask-X.Y.Z-macos-universal.zip`, signed with a Developer ID and
notarized (D50): unzip it into `/Applications`.

The app tells you about a newer release but installs nothing ([Update](#update)). Its app menu
has Check for Updates…, which runs `skillcask self-check`; it checks daily only after you say yes
once (it asks in the sidebar; Settings › Updates switches it). A newer version gets a card and a
sheet with the Homebrew command to copy, or the release page for a download (D51).

`macos/bundle.sh` builds a universal `Skillcask.app` that carries its own CLI at
`Contents/Helpers/skillcask`. Run outside a bundle (`swift run` from `macos/`), the app uses the
path set in its Settings, else looks on `PATH`, in `/opt/homebrew/bin`, `/usr/local/bin` and
`~/.cargo/bin`. Building it needs Xcode 26.x with Swift 6.3 or newer, not only the Command Line
Tools. Building, signing, Gatekeeper, tests and renders: [macos/README.md](macos/README.md).

## Design

See [docs/specs/2026-10-19-skillcask-v1.md](docs/specs/2026-10-19-skillcask-v1.md).

## License

MIT OR Apache-2.0.
