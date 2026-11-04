# Security

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
  `deny-patterns = true` under `[policy]` (or enforced in `config.toml`) they, and the invisible
  characters above, fail the command with exit 1 and nothing is written.
- `skillcask audit` reviews what is installed now, every skill in `.agents/skills` and the project
  skills: the commands its shell code blocks run, the hosts of its URLs, the paths in the home
  directory or under system roots, the environment variables it reads and the files an agent could
  run. That is read from the text, so it is a hint for review, not a sandbox, and a skill without
  findings is not known to be safe. It also reports a locked skill that differs from the lock, and
  every risky line and invisible character above, with no limit per file, and exits 1 on any of
  them.
- `skillcask audit --advisories` also asks the sources of the locked packages what is published
  about them: security advisories from a Composer repository that offers them (Packagist does) and
  from a GitHub repository's security advisories, matched against the locked version, and
  packages marked abandoned. An entry locked at a commit has no version to match, so only
  advisories published after that commit count. A source that cannot be read fails the run;
  packages whose source publishes no advisories, and plain git entries, are listed as unchecked.
  Plain `audit` stays offline. To warn users of
  your skill, publish a GitHub security advisory on its repository (for a Composer package, with
  the `composer` ecosystem and the package name, so Packagist lists it too).
- `--sarif` prints a SARIF 2.1.0 log for code scanning, e.g. in GitHub Actions. Scripts a skill
  bundles with their own dependencies (`package.json`, `requirements.txt`) are not covered by
  `--advisories`; [OSV-Scanner](https://github.com/google/osv-scanner) checks those:

  ```yaml
  - uses: GetResponse/skillcask@v0.10.5
    with:
      args: install --frozen
  - run: skillcask audit --advisories --sarif > skills.sarif
    env:
      GITHUB_TOKEN: ${{ github.token }}   # anonymous GitHub API calls are limited to 60 an hour
  - uses: github/codeql-action/upload-sarif@v3
    if: always()
    with:
      sarif_file: skills.sarif
  # optional, needs osv-scanner on PATH (e.g. google/osv-scanner-action): dependencies of bundled scripts
  - run: osv-scanner scan source -r .agents/skills
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
