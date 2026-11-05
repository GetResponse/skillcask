# Use

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

## skills.toml

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
deny-patterns = false    # true: risky patterns and invisible characters in new skill text fail instead of warning
deny-packages = ["evil/*"]   # refused by name from any source, also in a lock; default: none
```

## Agents

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

## Dependencies

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

## Name conflicts

Skills have no namespaces: an agent knows a skill by its name. Two skills with the same name in
one project are an error. Install one of them under another name with `rename`:

```toml
"mattpocock/skills" = { github = true, rename = { code-review = "mp-code-review" } }
```

skillcask then installs `.agents/skills/mp-code-review` and changes the `name:` line in its
`SKILL.md`; the lock records the original name and the hash of the renamed copy. Nothing else in
the skill changes, so text that mentions the old name (`/code-review`) stays as it is.
`add`, `install` and `update` offer the rename when they hit a conflict in a terminal.

## Personal skills (`--global`)

`skillcask --global` (`-g`) manages skills for your user instead of a project, with the same
manifest, lock and verification:

```sh
skillcask -g add github:mattpocock/skills/grill-me
skillcask -g install --frozen    # e.g. from a dotfiles repository
```

- `skills.toml`, `skills.lock` and an optional `auth.json` live in `~/.config/skillcask`
  (`$XDG_CONFIG_HOME/skillcask`; `SKILLCASK_HOME` overrides both). Keep them in your dotfiles.
- Skills go to `~/.agents/skills` (read by most agents), with links in `~/.claude/skills`
  (`[agents] targets`, see [Agents](#agents)). Links are absolute, so a symlinked
  `~/.claude` works. `[agents] local` does not apply.
- Personal skills you wrote by hand stay where they are and are not linked anywhere. `status`
  lists them, and copies other tools put in a target, as `not managed`; `status --json` names the
  source `npx skills` recorded for one. `skillcask -g add --adopt <source>` moves such a skill to
  `~/.config/skillcask/adopted/` and installs the package's skill of the same name in its place.
- The list of managed paths is `~/.agents/skills/.skillcask-installed`, local to the machine;
  nothing touches git.
- `skillcask init` in a project copies `[repositories]` of the global `skills.toml`, when it has
  one, in place of the default sources, so a company registry (or `packagist = false`) set up on
  the machine is in every new project. Only `init` reads it; the project's `skills.toml` stays
  the whole truth afterwards.
- `skillcask -g repository add <name> <url>` puts a registry into that table without touching your
  skills, and creates the file when it is missing; `skillcask -g repository remove packagist` turns
  Packagist off. Device management can run both on every check-in.
