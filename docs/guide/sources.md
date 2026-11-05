# Sources

## Skills from GitHub and skills.sh

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

## Skills from any git repository

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
