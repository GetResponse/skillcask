# Spec: source policy and default sources

Date: 2026-10-20. Status: implemented.

## Problem

An organisation that may only install skills from its private registry has two switches today:
`policy.packagist = false` and leaving out `github = true`. Nothing stops a project, a dependency
(D16) or a committed lock from pulling from another host, and nothing applies one rule to every
project on a machine or in CI. The default sources (Packagist, the GitHub API) are implicit, so a
reader of `skills.toml` does not see them.

## Goals

1. `allow-sources` lists the only sources skills may come from; everything else is refused at
   resolution and at install from the lock, except the dist host of a registry the list admits
   (see Enforcement).
2. Policy comes in layers: environment, user config, project. The user config can fix a key so a
   project cannot change it, or only provide a default.
3. `init` lists the default sources in `[repositories]`.

## Non-goals

- Repositories shared through the user config (one private registry declared for all projects).
- A system-wide config (`/etc`).

## Layers

Keys: `min-release-age`, `allow-ranges`, `packagist`, `github-requires`, `allow-sources`,
`deny-patterns` (D31), `deny-packages` (D57, an enforced list is a floor). The first layer that sets
a key wins:

1. Environment: `SKILLCASK_MIN_RELEASE_AGE`, `SKILLCASK_ALLOW_RANGES`, `SKILLCASK_PACKAGIST`,
   `SKILLCASK_GITHUB_REQUIRES`, `SKILLCASK_ALLOW_SOURCES` (comma-separated),
   `SKILLCASK_DENY_PATTERNS`. Empty is unset.
2. User config `config.toml` in the config dir of D13 (`$SKILLCASK_HOME`,
   `$XDG_CONFIG_HOME/skillcask`, `~/.config/skillcask`), keys listed in `enforce`. A project that
   sets an enforced key to another value is exit 1 naming the key and the file, unless the
   environment sets the key: then the project's value is unused. Against an enforced key the
   environment may only tighten: a longer `min-release-age`, `deny-patterns = true`,
   `allow-ranges`, `packagist` or `github-requires` false, an `allow-sources` whose every entry
   lies inside an enforced one. A looser value is exit 1 naming the variable, both values and the
   file.
3. `[policy]` of the project (or global) `skills.toml`.
4. User config, keys not in `enforce`.
5. Built-in defaults.

```toml
# ~/.config/skillcask/config.toml
[policy]
allow-sources = ["https://gitlab.example.com/", "github"]
min-release-age = "3d"
enforce = ["allow-sources"]
```

An enforced `min-release-age` also binds the per-repository values of D15 (D28): a project's
`min-release-age` on a repository may be longer, never shorter (exit 1 naming the repository);
a repository without one gets the enforced value. `config.toml` lists the exceptions by
`https://` URL prefix, longest match wins, and only next to `enforce = ["min-release-age"]`:

```toml
[policy.repository-min-release-age]
"https://gitlab.example.com/" = "0"   # reviewed in merge requests
```

Only `[policy]` is read from `config.toml`; any other table is exit 1, so a typo does not
silently drop a rule. CI without the file applies the project and the environment.

## Threat model

`enforce` keeps a project from loosening the policy for what it resolves: a cloned repository's
`skills.toml` and its dependencies (D16) cannot change an enforced key. Every install, also
`--frozen`, holds the lock to every key but `deny-patterns`: an enforced `allow-sources`,
`allow-ranges` (through the manifest's constraint), `github-requires`, `packagist = false`, and an
enforced or environment `min-release-age` (D7), the latter by the `released` time the lock records;
a repository's own `min-release-age` (D15) still applies under an environment cooldown.
`deny-patterns` applies when a version is resolved (D23, D31), not to a version the lock already
pins, and a forged `released` is not detected, so the lock change is still what to review.

It guards against what a project brings, not against whoever runs skillcask:

- The environment cannot loosen an enforced key, only tighten it (layer 1), so a CI job or a wrapper
  can make one run stricter, and a project's CI configuration cannot lift an enforced key through
  the `SKILLCASK_*` policy variables; it can still point `SKILLCASK_HOME`, `XDG_CONFIG_HOME` or
  `HOME` elsewhere (next bullet), so a rule nobody may skip also needs the job and
  `.github/workflows/` protected. A longer `SKILLCASK_MIN_RELEASE_AGE` raises the per-repository
  floor of D28 with it.
- `SKILLCASK_HOME`, `XDG_CONFIG_HOME` and `HOME` (else `USERPROFILE`, through the
  `~/.config/skillcask` fallback) choose which `config.toml` is read; pointed at another directory,
  no key is enforced at all.
- The user owns `config.toml` and can edit it.

Redirects are followed without checking `allow-sources` per hop (only the credential is looked up
again), so a server inside an allowed prefix can send a download elsewhere; an allowed prefix
vouches for every server under it.

Policy governs packages. A project's own skills (`local`, `.skills` by default) and skills written
by hand into `.agents/skills` are its code, reviewed like it; `audit` scans them.

skillcask runs with the user's rights and does not try to stop them; only the operating system
could, with a config directory the user cannot write (managed by MDM, which also makes the global
`skills.toml` and `skills.lock` of D13 read-only, not the store they install into) and a locked
environment. A rule nobody may skip is checked where the developer does not control the run: a
required check on pull requests to the default branch, with the policy in the job's environment,
that runs `install --frozen`. That holds every merged lock to every key but `deny-patterns` (a
repository's own `min-release-age` included, unless `config.toml` enforces the key); `deny-patterns`
of a version the lock pins, and the truth of its `released`, are left to the review of the lock
change. On `pull_request` GitHub runs the pull request's own copy of the workflow, so the job's
environment is only as strong as the protection of `.github/workflows/` (a required workflow in a
ruleset, or CODEOWNERS with required review).

## allow-sources

Absent: every source is allowed. Each entry is one of:

- `packagist`: `https://repo.packagist.org`;
- `github`: the GitHub API in use (`<api>/repos/…`). From the environment or an enforced key it
  means `<api>/repos/` of the API the user or the CI runner names only (D43), so a project's
  `github` url cannot widen it;
- an `https://` URL prefix, matched on a `/` boundary (`https://api.github.com/repos/acme/`
  allows the GitHub organisation `acme` only). Both sides are compared as parsed URLs, so no
  spelling of `..` leaves the prefix; below it a `..` behind `%2F` or `%5C` is refused too. An
  entry that does not parse as a URL is an error;
- in `skills.toml` only: a repository name from `[repositories]`, matching its URL. In
  `config.toml` and the environment a name would mean whatever a project calls that name, so
  only the forms above are accepted. Only such an entry, neither a keyword nor an `https://` URL,
  is compared with a repository's name: `[repositories]` keys are not validated, and a key spelled
  like a URL entry must not be "named" by it.

An `https://` entry without a trailing `/` also names a registry declared at exactly that URL, so
its dists may come from any host (Enforcement); end a prefix with `/`. An environment that narrows
an enforced prefix to such an exact URL thereby trusts that registry's dist hosts, which is within
"the environment is the user's" (layer 1), though `tightens` compares sources only.

A source is the URL a lock entry records in `repository`. Enforcement:

- Lookup searches allowed repositories only; blocked ones get no request. An entry whose
  `repository = "…"` or locked repository is blocked is exit 1, not a fall-through to another
  repository.
- GitHub sources are checked before the first API request.
- Every command that writes or installs checks every lock entry: a package from a blocked source
  is exit 1, also under `install --frozen`.
- With `allow-sources` set, a lock entry's archive is downloaded (by `install`, `info` or `diff`)
  only from what was checked. A repository under a GitHub API (`<api>/repos/`: the one in use, the
  trusted one of D43, or the text before `/repos/` in any `https://` entry, exact ones included)
  must be exactly `<api>/repos/<owner>/<name>` and downloads only `<repository>/zipball/<sha>` of
  a 40-hex commit. Packagist, and a repository of `[repositories]` the list names (by a name
  entry, never a keyword or a URL) or gives by its exact URL without a trailing `/`, download
  their dist from wherever the lock says, since registries serve dists from other hosts; review
  lock changes for those. Any other repository of `[repositories]` is admitted only by a prefix,
  which a project can declare a registry under or at, so its dist must pass `allow-sources` too.
  Everything else downloads only as a git checkout of itself.
- Dependencies (D16) follow the same rules.

## Default sources

`init` writes them:

```toml
[repositories]
packagist = { url = "https://repo.packagist.org" }
github = { type = "github", url = "https://api.github.com" }
```

- `packagist = false` and `github = false` turn a default source off. A missing line keeps it,
  so manifests written before this change behave as before; `allow-sources` is the hard block.
- Packagist is searched last wherever its line stands, so a private package is never shadowed
  by a public one with the same name.
- `type = "github"` is accepted only on the key `github`. Its `url` is the API base (GitHub
  Enterprise); `SKILLCASK_GITHUB_API` still overrides it. `min-release-age` is not accepted
  there; GitHub sources use the policy value (D15).
- `policy.packagist = false` keeps working.

## status

After the table, `status` prints each policy key that does not come from the built-in defaults,
with its layer: `allow-sources = ["acme"] (config.toml, enforced)`.

## Testing

- Unit: layer precedence for each layer, enforce conflict, env parsing, URL prefix boundary
  (`https://git.example.com` does not allow `https://git.example.com.evil/`, `<prefix>/../other/` or
  `<prefix>/..%2Fother/`), names refused in `config.toml`, Packagist ordered last, `github = false`.
- Integration: allow-sources limited to a private repository blocks a Packagist-only package without
  a request to it; a lock entry from a blocked source fails `install --frozen`; an enforced key in
  `config.toml` beats the project, and the environment may only tighten it; a dependency from a
  blocked source fails; `status` shows the origin.
