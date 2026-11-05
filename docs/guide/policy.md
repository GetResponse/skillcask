# Allowed sources and policy for every project

`allow-sources` lists the only places skills may come from: repository names, `packagist`, `github`,
or `https://` URL prefixes (`https://api.github.com/repos/acme/` allows one GitHub organisation).
End a prefix with `/` (`https://gitlab.example.com/`): an entry without one also names a registry
declared at that URL (with or without a trailing `/`), whose archives may then come from any host.
A URL entry must be written as it parses: no spaces, `?`, `#` or `\`, and a lowercase host. Other
repositories get no request, and `install` refuses a lock entry from them, also with `--frozen`, so
a committed lock cannot bring them back. Dependencies follow the same rule.

`deny-packages` refuses packages by name, `vendor/name` or a whole `vendor/*`, whatever source
serves them (a GitHub `owner/repo` counts as `owner/repo`). A plain git entry is matched by its key
in `skills.toml`, which the project picks, so limit git URLs with `allow-sources`. It is checked
before any download and again on every lock entry, so it also stops a dependency or a committed
lock. Enforced in `config.toml`, the list is a floor: a project may add packages to it, not drop
any.

Policy can also come from `config.toml` next to the global manifest (`~/.config/skillcask`) and
from the environment. The first layer that sets a key wins:

1. `SKILLCASK_ALLOW_SOURCES`, `SKILLCASK_MIN_RELEASE_AGE`, `SKILLCASK_ALLOW_RANGES`,
   `SKILLCASK_PACKAGIST`, `SKILLCASK_GITHUB_REQUIRES`, `SKILLCASK_DENY_PATTERNS`,
   `SKILLCASK_DENY_PACKAGES` (lists comma-separated; against an enforced key only a stricter value
   is accepted: a longer cooldown, `deny-patterns` on, the others off, narrower sources, more
   denied packages);
2. keys `config.toml` lists in `enforce`: a project that sets them otherwise fails;
3. `[policy]` in `skills.toml`;
4. the other keys of `config.toml`, as defaults.

```toml
# ~/.config/skillcask/config.toml: only the company registry and GitHub, in every project
[policy]
allow-sources = ["https://gitlab.example.com/", "github"]
enforce = ["allow-sources"]
```

`"github"` in an enforced `allow-sources` is public GitHub (`https://api.github.com/repos/`):
`SKILLCASK_GITHUB_API` and `GITHUB_API_URL` do not move it. For GitHub Enterprise, enforce its
prefix, e.g. `"https://ghe.example.com/api/v3/repos/"`.

An enforced `min-release-age` also applies to a repository's own `min-release-age`: a project
may only make it longer. Exceptions, by URL prefix, stay in `config.toml`:

```toml
[policy]
min-release-age = "3d"
enforce = ["min-release-age"]

[policy.repository-min-release-age]
"https://gitlab.example.com/" = "0"   # internal skills, reviewed in merge requests
```

`enforce` stops a project and its dependencies from loosening the policy for what they resolve, and
a lock entry from a source outside an enforced `allow-sources`, or younger than an enforced
`min-release-age`, or an environment one where the project's repository sets none, from installing;
a repository's own `min-release-age` still applies under an environment cooldown, so a cooldown
nobody may skip needs `config.toml` to enforce it. The environment, which a project's CI
configuration also sets, may only make an enforced key stricter. A pinned version is not scanned
again for `deny-patterns`, and its release time is what the lock says. Under `allow-sources`, a
GitHub or git entry downloads only from its repository, and a registry the list admits only by a
prefix only from inside the list; the archive URL of Packagist or a registry the list names (or
gives by its exact URL, without a trailing `/`) is what the lock says, so review lock changes.
`enforce` does not stop the person running skillcask: `SKILLCASK_HOME`, `XDG_CONFIG_HOME` or `HOME`
can point at a config without it. For a rule nobody may skip, run `skillcask install --frozen` as a
required check on pull requests, with the policy in the job's environment and `.github/workflows/`
protected (CODEOWNERS or a required workflow), since a pull request runs its own copy of the
workflow.

`config.toml` and the environment take URL prefixes, not repository names, since a name means
whatever a project calls it. `skillcask status` prints each key that is set and where it came
from.
