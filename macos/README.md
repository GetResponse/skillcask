# Skillcask for macOS

A SwiftUI app over the `skillcask` CLI (spec D35). It runs on macOS 14 or newer; building it needs
Xcode 26.x with Swift 6.3 or newer (CI builds it with Xcode 26.6, Swift 6.3.3; Xcode 26.0 to 26.3
ship Swift 6.2). The Command Line Tools alone are not enough: SwiftUI's macro plugins (`@State`,
`@Entry`, `#Preview`) ship only with Xcode, so `test.sh` and `bundle.sh` stop at once without it.
How the app looks and behaves, and the rules it keeps: [DESIGN.md](DESIGN.md).

## Try it

```sh
macos/bundle.sh                    # universal Skillcask.app with the CLI inside, plus a zip
open macos/.build/Skillcask.app
```

Without a bundle, `swift run Skillcask` from `macos/` starts the app against the CLI it finds: the
path set in Settings, else `PATH`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.cargo/bin`.
`SKILLCASK_UI_FIXTURES=1 swift run Skillcask` starts it on the built-in sample data and runs no CLI.
The app needs skillcask 0.9.4 or newer and asks to upgrade an older one.

Update check (D51): app menu › Check for Updates… runs `skillcask self-check --json` (a CLI that
lacks it, older than 0.10.2 and not the bundled one, is never asked). The daily check is off until
the user says yes once in the sidebar card; Settings › Updates switches it and shows the last
check. The app shows the Homebrew command or the release page; it never installs anything. A run
without a bundle version (`swift run`), the sample data and `smoke-app.sh` check nothing.

Live refresh (spec D53): the selected scope's manifest, lock, `config.toml`, store, project skills
directory and agent directories are watched (FSEvents), so a change made in a terminal or by an
agent shows within about a second, and returning to the app reads a scope older than a minute
again; these refreshes are quiet (no fade), run no network command and add no Activity row. A
change made within 2 s of the app's own change is taken as the app's and shows at the next one.

## Build the app

`bundle.sh` builds the app (one universal SwiftPM build) and the CLI (one cargo build per
architecture, joined with `lipo`) from this repository for arm64 and x86_64, renders the icon from
`icon.svg` (Quick Look, `sips` and `iconutil`, all part of macOS), and writes:

- `macos/.build/Skillcask.app`, with the CLI at `Contents/Helpers/skillcask`, which the app prefers
  over `PATH` unless Settings names a binary;
- `macos/.build/Skillcask-<version>-macos-universal.zip`.

The version is the one in `Cargo.toml`. `SKILLCASK_CLI=<path>` bundles a prebuilt CLI instead;
`SIGN_IDENTITY` picks the signing identity (default `-`, ad hoc). Both Rust targets must be
installed (`rustup target add aarch64-apple-darwin x86_64-apple-darwin`) unless `SKILLCASK_CLI` is
set.

## Signing and Gatekeeper

A local build is signed ad hoc with the hardened runtime, inside-out (the helper, then the app),
not notarized: it opens on the machine that built it. Gatekeeper blocks a downloaded copy ("cannot be
opened" / "damaged"). On macOS 14, right-click the app and choose Open. On macOS 15 and later, try
to open it once, then choose Open Anyway in System Settings › Privacy & Security. Clearing the
quarantine flag after unzipping also works, but do it only for a copy you built yourself or got from
a source you trust:

```sh
xattr -dr com.apple.quarantine Skillcask.app
```

Releases do not have this problem: `publish-macos-app` in `.github/workflows/release.yml` builds the
app with the released CLI, signs it with a Developer ID (`SIGN_IDENTITY="Developer ID Application:
…"`), notarizes and staples it, and attaches the zip to the GitHub Release; the cask
`skillcask-app` in `puniserv/homebrew-tap` installs that zip (D50,
`docs/specs/2026-10-28-macos-app-release.md`).

## Test

```sh
macos/test.sh                      # lint, build and tests; fails on any compiler warning
macos/Scripts/smoke-app.sh         # launches the built app and checks it uses the bundled CLI
```

Extra arguments go to `swift test` (`macos/test.sh --filter ProcessRunner`);
`SKILLCASK_BIN=<path>` also runs the contract tests against that CLI. An incremental build hides
warnings in unchanged files, so trust a count of 0 only after `swift package clean`. CI's
`macos-app` job runs `test.sh` on a clean checkout.

`smoke-app.sh` needs a logged-in GUI session. It checks the app's `--version` refusal, then starts
the built app on the sample data, again over a saved column layout whose columns overlap (it must
be dropped), and live (with a fresh `SKILLCASK_HOME` and a `PATH` without skillcask;
`-appUpdates.consent declined`, so no update check), signals only the processes it started, and
afterwards restores the app's defaults and saved window state, or removes those the run wrote when
there were none.

## Render the previews

```sh
TZ=UTC macos/Scripts/render-previews.sh           # every registered preview (UTC: dates match on every Mac)
macos/Scripts/render-previews.sh --list           # the preview ids
macos/Scripts/render-previews.sh P1-1             # one id or prefix
```

Each preview is drawn offscreen in light and dark at 2x into
`macos/.build/renders/<id>/{light,dark}/<state>.png` (git-ignored). The script fails when the build
fails or a PNG is missing or blank.
