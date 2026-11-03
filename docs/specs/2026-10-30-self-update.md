# Spec: `skillcask self-update`

Date: 2026-10-30. Status: accepted as D52 (2026-10-30), which amends D51.

## Problem

`skillcask self-check` (D51) says that a newer release exists, and the README tells people to update
"the same way you installed". Most people do not remember how they installed, and the commands
differ per method: `brew upgrade`, `npm install -g`, `cargo install`, or the release's installer
script run again. Only the installer script can be re-run by skillcask itself without fighting a
package manager.

Goal: one command that updates an installer-script install and, for every other method, prints the
exact command to run.

## Constraints

- **The shell installer and `cargo install` both write `~/.cargo/bin/skillcask`.** dist installs
  to `CARGO_HOME` (`install-path = "CARGO_HOME"` in `dist-workspace.toml`), so the path alone does
  not tell them apart.
- **The installer writes a receipt**: `$XDG_CONFIG_HOME/skillcask/skillcask-receipt.json` (default
  `~/.config/skillcask/`; `%LOCALAPPDATA%\skillcask\` on Windows) with `install_prefix`,
  `install_layout` and `version`. `cargo install` writes `~/.cargo/.crates2.json` (or
  `$CARGO_HOME/.crates2.json`) instead. A later `cargo install` over an installer install leaves
  the receipt behind.
- **A running binary cannot simply be overwritten.** Linux refuses to write an executing file
  (`ETXTBSY`), macOS may kill a process whose signed pages change, Windows locks a running `.exe`.
- **The installer verifies the archive, not itself.** Each `skillcask-installer.sh` embeds the
  sha256 of every archive of its release and checks the download; the script itself has no
  published checksum. Its integrity rests on HTTPS to github.com, as for the first `curl | sh`.
- **`install --frozen` and the package invariants are untouched.** The installer is skillcask's own
  release artifact, not package content; skillcask still never runs anything from a package.

## Proposal

### 1. Command

`skillcask self-update [--dry-run]`, outside any project, like `self-check`. No `--json`, no
`-g`, no confirmation prompt: running the command is the consent. `--dry-run` prints the detected
method and the command or installer URL it would use, and runs nothing.

### 2. Latest version

The same anonymous request as `self-check` (D51). No newer version: prints
`skillcask X is the latest` and exits 0. Unparsable `latest`: exits 1 and names the release page.

### 3. Install method

From `std::env::current_exe()` with symlinks resolved, first match wins:

| Detected | Action |
| --- | --- |
| path inside `*.app/Contents/Helpers/`, `<prefix>/Caskroom/skillcask-app` exists | `brew update && brew upgrade skillcask skillcask-app`, exit 1 |
| path inside `*.app/Contents/Helpers/` otherwise | the tagged `skillcask-app-installer.sh … \| SKILLCASK_VERSION=<latest> sh`, exit 1 |
| path contains `/Cellar/` | `brew update && brew upgrade skillcask`, exit 1 |
| path contains `/.bun/` | `bun add -g skillcask@latest`, exit 1 |
| path contains `/node_modules/` | `npm install -g skillcask@latest`, exit 1 |
| exe is `<cargo_home>/bin/skillcask` and `.crates2.json` lists `skillcask` | `cargo install --locked skillcask`, exit 1 |
| receipt with `install_layout` `cargo-home` and exe `== <install_prefix>/bin/skillcask` | Unix: run the installer (§4). With `SKILLCASK_SELF_UPDATE=0`: the tagged `curl … \| sh`. Windows: `powershell -ExecutionPolicy Bypass -c "irm …/v<latest>/skillcask-installer.ps1 \| iex"` (works from `cmd.exe` too). Exit 1 when printed |
| anything else | the release page, exit 1 |

Printed as `skillcask X -> Y: installed with <method>; update with:` and the command alone on the
`hint:` line, so it can be pasted. `.crates2.json` comes before the receipt because both live in
`~/.cargo`. Exit 1 means "nothing was updated, run this", so a script does not mistake a printed
hint for success.

### 4. Running the installer (Unix)

1. Without `sha256sum` on `PATH`, exit 1 with the command: dist 0.32's script skips its archive
   check then (no `shasum` fallback).
2. `GET <base>/v<latest>/skillcask-installer.sh` with `Http::anonymous` (no credential, D51), at
   most 256 KiB (the 0.10.1 script is 55 KiB). `<base>` is
   `https://github.com/GetResponse/skillcask/releases/download`; `SKILLCASK_SELF_UPDATE_URL` replaces
   only the base, for tests and mirrors, so the tag still follows the reported version, and a
   warning names it.
3. Write it to an unnamed temp file (`tempfile::tempfile`), so nothing is left behind.
4. Print `updating skillcask X -> Y with <url>`, then `exec` `/bin/sh -s` with that file as stdin.
   Every `SKILLCASK_*`, `INSTALLER_*` and `CARGO_DIST_*` variable is removed first: the script reads
   `SKILLCASK_DOWNLOAD_URL`, `INSTALLER_DOWNLOAD_URL`, `SKILLCASK_INSTALLER_GITHUB_BASE_URL`,
   `SKILLCASK_GITHUB_TOKEN`, `SKILLCASK_UNMANAGED_INSTALL`, `CARGO_DIST_FORCE_INSTALL_DIR` and more,
   which would change where archives come from, which token goes there, or where it installs. Then
   `SKILLCASK_INSTALL_DIR=<install_prefix>` and `SKILLCASK_NO_MODIFY_PATH=1`: the same as the
   documented `curl … | sh`, into the same directory, without editing shell profiles again.

`exec` replaces the skillcask process with `sh`, so nothing of skillcask runs while the installer
replaces the binary, and the installer's exit code is the command's. A failed download exits 3
before `exec`. `SKILLCASK_SELF_UPDATE=0` turns step 1-4 into printing the command, for machines whose
admin owns updates.

### 5. Documentation

README "### Update": `skillcask self-update` first; it runs the installer for an installer-script
install and prints the command for every other one. Exit codes and the privacy notes say what it
sends and runs. D52 records the decision and amends D51's "skillcask does not update itself" and
D10.

## Tests

- Unit tests for the detection table on fake paths, receipts and `.crates2.json` in a temp dir.
- `tests/self_update.rs`, against a local server through `SKILLCASK_SELF_CHECK_URL` and
  `SKILLCASK_SELF_UPDATE_URL`: up to date, unknown install, `cargo install`, and on Unix the test
  binary copied to `~/.cargo/bin` with a receipt, where a served script records its environment
  (the real `exec`), `--dry-run` runs nothing and the script's exit code comes back.

## Rejected

- **`axoupdater`** (dist's updater crate, `install-updater = true`): it does the same, but brings
  its own HTTP stack next to `Http` and a second set of network rules to keep in line with D43/D51.
- **Downloading the archive and swapping the binary in skillcask**: a self-updater with its own
  checksum, rename and rollback code, for what the installer already does and verifies.
- **Running the installer on Windows**: the running `.exe` is locked; renaming it aside and cleaning
  up a `.old` file later is code and risk for one command that the user can paste.
- **Running `brew`, `npm` or `cargo` for the user**: they may need `sudo`, a different prefix or a
  shell with the right `PATH`; printing the exact command is enough.
