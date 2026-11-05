# Security policy

## Reporting a vulnerability

Report it privately through GitHub:
[Report a vulnerability](https://github.com/GetResponse/skillcask/security/advisories/new).
Do not open a public issue or pull request for it.

Include the skillcask version (`skillcask --version`), the OS, and the steps or a minimal
`skills.toml`, `config.toml` and environment that show the problem. We reply in the advisory
and publish it with the fixed release.

## Supported versions

Only the latest release gets security fixes. Update with your package manager or
`skillcask self-update`.

## Scope

Examples of what we treat as a vulnerability:

- `install` installs content that does not match the lock, or skips a hash check.
- A package makes skillcask run its code or write outside the skill's directory.
- A project or a dependency loosens a policy key that `config.toml` enforces.
- A credential is sent to a host it is not meant for.

The design and the threat model are in the [README](README.md#security) and in
`docs/specs/2026-10-19-skillcask-v1.md`.
