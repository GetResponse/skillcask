# Commands

Every command except `publish`, `validate` and `projects` takes `-g, --global`.

| Command | |
|---|---|
| `init` | Create `skills.toml`; `[repositories]` comes from the global `skills.toml` when it has one. |
| `add <vendor/name>[@constraint] [--repository r]` | Resolve, lock and install. |
| `add github:<owner/repo>[/skill][@version-or-ref]` | The same from a GitHub repository, [see Sources](sources.md#skills-from-github-and-skillssh). |
| `add git:<https-url>[@version-or-ref]` | The same from any git repository over HTTPS, [see Sources](sources.md#skills-from-any-git-repository). |
| `remove <vendor/name>…` | Drop from manifest and lock; delete files, links and gitignore lines. |
| `install [--frozen]` | Install the lock. `--frozen` (implied by `CI`) fails when the lock is out of date. |
| `update [vendor/name…] [--diff]` | Re-resolve within constraints. `--diff` prints what changes in each updated or added package; it does not ask before installing. |
| `outdated [--strict]` | Newer versions, when cooled-down ones become eligible, and GitHub or git tags moved since they were locked. `--strict` exits 1 when `update` would lock a newer version. |
| `diff [vendor/name] [--to constraint\|--from old.lock]` | Unified diff of skill files from the locked version to the one `update` would lock, or from an older lock to `skills.lock`, see below. |
| `info <vendor/name[@constraint]\|github:owner/repo\|git:url\|skill>` | A package's skills, versions, description, license and requirements, or which package installs a skill. |
| `status` | Exit 1 when manifest, lock or installed files disagree. Also lists the repositories in use (name, type, URL without credentials) and whether `allow-sources` admits each. |
| `doctor [--fix]` | Broken or committed links, stale gitignore block, modified skills; lists each check it ran. |
| `audit [--json\|--sarif] [--advisories]` | What each installed skill reaches (commands, hosts, paths, env vars, scripts) and its findings: modified files, risky lines, invisible characters; with `--advisories` also published security advisories and abandoned packages. Exit 1 on any finding. |
| `config [key [value…]] [--unset] [--json]` | Settings with where each comes from: `[policy]` and `[agents] targets` of `skills.toml`, or with `-g` of `config.toml` (also `policy.enforce` and `search.skills-sh`). `config policy.min-release-age 5d` sets a key, `--unset` removes it, each checked before the file is written; `config edit` opens the file in `$VISUAL`/`$EDITOR` and checks it afterwards. |
| `repository add <name> <url> [--min-release-age <age>]` | Add a repository to `[repositories]` of `skills.toml`, or replace the one of that name; `repository remove <name>` drops it, and turns `packagist` or `github` off. |
| `search [query] [--skills-sh\|--no-skills-sh [--remember]]` | Packagist (`type=ai-agent-skill`) and skill packages of the other repositories, GitLab included; with skills.sh on, also the GitHub skills it lists, as `github:owner/repo/skill` with their install count. skills.sh is off until you turn it on, since it receives the query: the first search in a terminal asks once, `--remember` saves a flag's choice (no query needed), both in `config.toml`. |
| `auth set\|remove <host>` | Keep a registry token in git's credential helper (Keychain, Credential Manager, libsecret). |
| `publish --vendor v --base-url URL --out DIR [--inline] [--dist-url TPL] [paths…]` | Build a static Composer repository from a monorepo. |
| `validate [paths…]` | Check `SKILL.md` files against the Agent Skills spec, [see Publishing skills](publishing.md). |
| `projects [dirs…]` | Directories that hold `skills.toml` under the given ones (default: the current one), up to 6 levels down; hidden directories, `node_modules`, `vendor`, `target` and `Library` are skipped. |
| `ui` | A terminal UI over the commands above: skills with their state and updates, `info`, SKILL.md and `audit` per skill, add, adopt (also offered when an add hits a skill skillcask does not manage), update (diff first), remove, doctor, a filter of the list, search of the registries (and skills.sh, asked once), the repositories in use (`R`, `S` turns skills.sh on or off) and a projects picker; `g` switches between the project and `--global`. |
| `app` | Opens the macOS app (see [macOS app](macos-app.md)); exits 1 when it is not installed, and on Linux and Windows. |
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
