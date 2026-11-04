# Install

**macOS, Linux**

```sh
brew install getresponse/tap/skillcask
# or, without Homebrew:
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/GetResponse/skillcask/releases/latest/download/skillcask-installer.sh | sh
```

**Windows (PowerShell)**

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://github.com/GetResponse/skillcask/releases/latest/download/skillcask-installer.ps1 | iex"
```

The two installer scripts download the binary for your platform from the latest release and put
it in `~/.cargo/bin` (`%USERPROFILE%\.cargo\bin` on Windows).

**Desktop app (macOS 14+ only for now)**

```sh
brew install getresponse/tap/skillcask getresponse/tap/skillcask-app
skillcask app                   # or open Skillcask from Applications
```

Install with the full names: Homebrew loads a third-party tap's cask only when it is named in full
(or listed by `brew trust`); after that, `brew upgrade` takes the short name.

The tap was `puniserv/tap` before 0.10.5. If you installed from it, move to the new name once
(your app settings stay):

```sh
brew uninstall --cask puniserv/tap/skillcask-app   # skip if you have no app
brew uninstall puniserv/tap/skillcask
brew untap puniserv/tap
brew install getresponse/tap/skillcask getresponse/tap/skillcask-app
```

Without Homebrew:

```sh
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/GetResponse/skillcask/releases/latest/download/skillcask-app-installer.sh | sh
```

The installer downloads `Skillcask-X.Y.Z-macos-universal.zip` (signed and notarized, with its own
CLI inside) from the latest release, checks its sha256 and Gatekeeper's verdict, and moves the app
to `/Applications`; an earlier copy goes to the Trash. It leaves a Homebrew install alone.
`SKILLCASK_VERSION=X.Y.Z` picks a release, `SKILLCASK_APP_DIR` another folder.

Linux and Windows have the terminal UI, `skillcask ui`. More in [macOS app](macos-app.md).

**npm, bun**

```sh
npm install -g skillcask      # global
bun add -g skillcask          # global, bun
npx skillcask install --frozen
bunx skillcask install --frozen
```

The npm package is a thin wrapper that downloads the release binary for your platform from
GitHub. It does not check a checksum itself; where that matters, use Homebrew or a release
archive and verify it.

**Cargo**

```sh
cargo install --locked skillcask
```

**Release archives** for macOS, Linux and Windows are on the
[releases page](https://github.com/GetResponse/skillcask/releases), with sha256 checksums and GitHub
build provenance attestations:

```sh
gh attestation verify skillcask-x86_64-unknown-linux-gnu.tar.xz -R GetResponse/skillcask
```

Releases up to 0.10.2 were built before the repository moved and verify with `--owner puniserv --signer-repo puniserv/skillcask`.

**GitHub Actions**

```yaml
permissions:
  contents: read
  attestations: read   # for the provenance check
steps:
  - uses: actions/checkout@<sha>
  - uses: GetResponse/skillcask@<commit sha of a release tag>   # vX.Y.Z
    with:
      version: X.Y.Z               # needed when the action is pinned to a sha, not a tag
      args: install --frozen       # default
      # working-directory: .
      # verify-attestation: "true" # default
```

The action downloads the release archive for the runner (Linux x64 and arm64, macOS, Windows
x64), checks its sha256 and its build provenance attestation, puts `skillcask` on `PATH` and runs
it with `args`. It runs no other action. Used at a tag (`@vX.Y.Z`) it takes the version from the
tag.

## Update

`skillcask self-update` reruns the release's installer when `skillcask-installer.sh` installed
this binary (Linux, macOS); for any other install it prints the one command to run and exits 1.
`SKILLCASK_SELF_UPDATE=0` makes it print the installer command too. By hand:

```sh
brew update && brew upgrade skillcask skillcask-app    # Homebrew (skillcask alone without the app)
npm install -g skillcask@latest                        # npm (bun: bun add -g skillcask@latest)
cargo install --locked skillcask                       # Cargo
```

The installer scripts (`skillcask-installer.sh`, `skillcask-installer.ps1`,
`skillcask-app-installer.sh`) install the latest release when run again; the app's installer moves
the earlier copy to the Trash. The app's own CLI updates with the app; Homebrew updates the app and
the CLI on your `PATH` separately, which is why `brew upgrade` names both. For the GitHub Action,
bump the pinned commit and `version`. `skillcask --version` prints what you have.
