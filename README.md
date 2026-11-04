<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/wordmark-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/wordmark-light.svg">
    <img alt="skillcask" src="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/wordmark-light.svg" width="480">
  </picture>
</p>

<p align="center">
  <strong>A lockfile-first package manager for AI agent skills.</strong><br>
  One manifest, one lock, every agent's skill directory.
</p>

<p align="center">
  <a href="https://github.com/GetResponse/skillcask/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/GetResponse/skillcask/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://crates.io/crates/skillcask"><img alt="crates.io" src="https://img.shields.io/crates/v/skillcask"></a>
  <a href="https://www.npmjs.com/package/skillcask"><img alt="npm" src="https://img.shields.io/npm/v/skillcask"></a>
  <a href="https://github.com/GetResponse/homebrew-tap"><img alt="Homebrew: getresponse/tap" src="https://img.shields.io/badge/homebrew-getresponse%2Ftap-orange"></a>
  <a href="#license"><img alt="License: MIT OR Apache-2.0" src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue"></a>
</p>

skillcask installs skills (directories with a `SKILL.md`, read by Claude Code, Codex, Junie and
others) the way Cargo or Composer install libraries: a manifest with version constraints, a
committed lock with content hashes, and frozen installs in CI that fail on drift. It ships as a
single static binary with no runtime, and takes skills from Composer repositories, GitHub (which
covers most of what [skills.sh](https://skills.sh) lists) and any git repository over HTTPS.

## Install

```sh
brew install getresponse/tap/skillcask      # macOS, Linux
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/GetResponse/skillcask/releases/latest/download/skillcask-installer.sh | sh
npm install -g skillcask                    # or: cargo install --locked skillcask
```

Windows, the desktop app, bun, release archives with attestations, the GitHub Action and updating:
[Install guide](docs/guide/install.md).

## Quickstart

```sh
skillcask init                                # create skills.toml
skillcask add netresearch/agent-jira-skill    # resolve, write skills.toml + skills.lock, install
skillcask add github:mattpocock/skills/tdd    # one skill from a GitHub repository
skillcask status                              # manifest vs lock vs installed files
skillcask install --frozen                    # CI: install exactly the lock or exit non-zero
```

Commit `skills.toml` and `skills.lock`; the installed skills are gitignored. In GitHub Actions,
`uses: GetResponse/skillcask@<commit sha of a release tag>` with `version: X.Y.Z` runs
`install --frozen` ([setup](docs/guide/install.md)).

## Why skillcask

- **Locked and verified.** The lock pins the version, the commit reference, the sha256 of the
  downloaded archive and the tree hash of every installed skill; `install` verifies both hashes.
- **Every agent.** Skills go to `.agents/skills`, which most agents read themselves, with links
  into `.claude/skills`, `.kiro/skills` or any directory you name.
- **Your sources.** Packagist, GitLab's Composer registry, Satis, Private Packagist, GitHub, any
  git server over HTTPS, or a static repository built by `skillcask publish`.
- **Reviewable updates.** A release-age cooldown (`init` writes `3d`), `outdated --strict` for
  scheduled jobs, and `diff` / `diff --from old.lock` to read the skill text a change brings in.
- **Policy for every project.** `allow-sources`, `deny-packages`, exact versions only, and keys that
  `config.toml` enforces so a project cannot loosen them.
- **Audit.** `audit` lists what each skill reaches (commands, hosts, paths, env vars, scripts),
  flags risky lines and invisible characters, and prints SARIF; `--advisories` also checks
  published security advisories.
- **Data only.** No package code runs, ever. No telemetry. No PHP, Composer or Node needed.

## How it works

```
skills.toml ──add/update──▶ skills.lock ──install──▶ .agents/skills/<name>/      read by Codex, Cursor, Gemini CLI, …
 manifest,                   lock, commit it          ├─▶ .claude/skills/<name>   link ([agents] targets)
 commit it                                            └─▶ .kiro/skills/<name>     link
```

`add` and `update` resolve the constraints in `skills.toml` and write the exact versions and
hashes to `skills.lock`; `install` installs exactly what the lock pins and fails on any hash
mismatch. Details: [Use](docs/guide/usage.md).

## macOS app

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/macos-app-dark.png">
  <img alt="Skillcask for macOS: a project's skills with their state, and the details of one skill" src="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/macos-app-light.png" width="800">
</picture>

<table>
  <tr>
    <td width="33%"><picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/macos-updates-dark.png">
      <img alt="Reviewing an update as a diff before applying it" src="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/macos-updates-light.png">
    </picture></td>
    <td width="33%"><picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/macos-audit-dark.png">
      <img alt="Security findings for a skill" src="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/macos-audit-light.png">
    </picture></td>
    <td width="33%"><picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/macos-add-dark.png">
      <img alt="Searching and adding a skill" src="https://raw.githubusercontent.com/GetResponse/skillcask/master/docs/assets/macos-add-light.png">
    </picture></td>
  </tr>
  <tr><td align="center">Review updates</td><td align="center">Audit findings</td><td align="center">Add skills</td></tr>
</table>

A SwiftUI app for macOS 14+ over the CLI: see each skill's state, updates and audit findings, read
its SKILL.md and diffs, and add, update or remove skills. Linux and Windows have the terminal UI,
`skillcask ui`.

```sh
brew install getresponse/tap/skillcask getresponse/tap/skillcask-app
```

More in [macOS app](docs/guide/macos-app.md).

## Documentation

| Guide | |
|---|---|
| [Install](docs/guide/install.md) | Every install method, the GitHub Action, updating |
| [Use](docs/guide/usage.md) | `skills.toml`, agents, dependencies, name conflicts, personal skills (`--global`) |
| [Commands](docs/guide/commands.md) | Every command, `--json`, exit codes, reviewing updates and lock changes |
| [Sources](docs/guide/sources.md) | Skills from GitHub, skills.sh and any git repository |
| [Policy](docs/guide/policy.md) | Allowed sources and policy for every project |
| [Security](docs/guide/security.md) | What is verified, warnings, `audit`, credentials |
| [Publishing skills](docs/guide/publishing.md) | Packages, monorepos with `skillcask publish`, `validate` |
| [macOS app](docs/guide/macos-app.md) | Installing and building the app |
| [Design](docs/specs/2026-10-19-skillcask-v1.md) | Goals, non-goals and numbered decisions |

## Security

HTTPS only, hashes checked on every install, archives that escape their skill rejected, and no
package code run. The threat model and every check are in [Security](docs/guide/security.md);
report a vulnerability as [SECURITY.md](SECURITY.md) describes.

## Contributing

Read [AGENTS.md](AGENTS.md) for the checks CI runs and the project's invariants, and the
[design spec](docs/specs/2026-10-19-skillcask-v1.md) before changing how the manifest, lock,
install or publish behave.

## License

MIT OR Apache-2.0.
