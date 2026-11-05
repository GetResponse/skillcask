# Publishing skills

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
