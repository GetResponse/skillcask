# skillcask guide

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

| Page | What it covers |
|---|---|
| [Install](install.md) | Homebrew, installer scripts, desktop app, npm and bun, Cargo, release archives, GitHub Actions, updating |
| [Use](usage.md) | What `add` creates, project skills, `skills.toml`, agents, dependencies, name conflicts, personal skills (`--global`) |
| [Commands](commands.md) | Every command, `--json`, exit codes, agent output, reviewing updates and lock changes |
| [Sources](sources.md) | Skills from GitHub and skills.sh, skills from any git repository |
| [Policy](policy.md) | Allowed sources and policy for every project, `config.toml`, `enforce` |
| [Security](security.md) | Lock hashes, archive checks, warnings, `audit`, credentials |
| [Publishing skills](publishing.md) | One repository per skill, monorepos with `skillcask publish`, `validate`, deprecation |
| [macOS app](macos-app.md) | The SwiftUI app over the CLI, installing and building it |

## Design

See [docs/specs/2026-10-19-skillcask-v1.md](../specs/2026-10-19-skillcask-v1.md).
