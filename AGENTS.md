# skillcask

Lockfile-first package manager for agent skills, shipped as one Rust binary. Design, non-goals and
numbered decisions (D1, D2, …) live in `docs/specs/2026-10-19-skillcask-v1.md`: read it before
changing how the manifest, lock, install or publish behave, and record a new decision there in the
same change.

## Checks

Run what CI runs before every commit:

```sh
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

`cargo test --locked --test cli -- --ignored` runs end-to-end against live Packagist; run it after
touching registry or HTTP code.

After touching `macos/` (macOS with Xcode 26.x and Swift 6.3+), run `macos/test.sh`: swift-format
lint, build and tests; it fails on any compiler warning. Trust 0 warnings only on a clean build
(`swift package clean`).

CI tests Linux, macOS and Windows. Paths, symlinks and exec bits must work on all three.

## Invariants

- Package content is data only: skillcask never runs scripts, hooks or plugins from a package.
- `install` installs exactly what the lock pins and fails on any hash mismatch.
- No telemetry.
- The repository is public: code, docs and commit messages name only public projects and services.

## Commits

Conventional Commits with a lowercase subject that states the outcome, e.g.
`fix: refuse symlinked project dirs and harden add, gitignore and CLI errors`.

## Release

1. Bump `version` in `Cargo.toml`, run `cargo build` to update `Cargo.lock`, commit
   `chore: release X.Y.Z`, push.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`. `release.yml` builds all targets and publishes the
   GitHub Release, Homebrew formula and npm package. Approve `publish-macos-app` under "Review
   deployments" (environment `release`); it attaches the signed, notarized macOS app zip, and
   `publish-homebrew-cask` then updates the cask `skillcask-app`. When the macOS arm64 runner is
   not acquired or notarization fails or times out, the CLI release stands: rerun the failed jobs
   (`gh run rerun <id> --failed`); for a rejection read the printed `notarytool log` first.
   When `publish-macos-app` has finished, approve `publish-macos-pkg` the same way (a second
   review); it attaches the signed, notarized installer package for device-managed Macs. A failed
   package job leaves the release, the app and the cask intact: rerun it with
   `gh run rerun <id> --failed`. Before telling administrators about the release, confirm it lists
   the `.pkg` and its `.sha256` (the `announce` job does not wait for them): device-management
   tooling silently stays on the previous release when the package is missing.
3. `cargo publish --locked` from the tag (manual).
4. Edit the GitHub Release in the browser, tick "Publish this Action to the GitHub Marketplace" and
   save (manual: GitHub has no API for it, and releases made by `release.yml` are not listed).

`release.yml` comes from `dist generate`, but it is hand-edited; re-apply the edits after
regenerating:

- `publish-npm` uses npm trusted publishing: `id-token: write`, an exact npm >= 11.5.1 at least
  3 days old, no `GH_TOKEN`, and no `registry-url` in `setup-node` (it injects a placeholder
  `NODE_AUTH_TOKEN` that breaks OIDC with E404).
- `publish-macos-app` is written by hand, not a dist custom publish job: dist skips those on
  pre-releases and gives them no `contents: write`. It keeps `environment: release`, where the
  signing secrets live. `publish-homebrew-cask` is hand-written too and writes the whole cask.
- `publish-macos-pkg` is hand-written too and runs `macos/pkg.sh` and `macos/Scripts/check-pkg.sh`:
  it keeps `environment: release`, needs `publish-macos-app`, compiles nothing and fails when its
  keychain holds a Developer ID Application certificate, so it signs with the Developer ID
  Installer certificate alone. Nothing needs it.
- Supply chain: every action pinned to a commit sha, the dist installer checked against a pinned
  sha256, and `GH_TOKEN: ""` on the steps that install tools.

The installer package is a published contract that does not change: its asset name
(`Skillcask-X.Y.Z-macos-universal.pkg`), its three identifiers (`com.getresponse.skillcask.pkg`,
`.pkg.app`, `.pkg.cli`; in the organisation's reverse-domain namespace, while the app keeps its
bundle id `io.github.puniserv.skillcask`) and its install paths (`/Applications/Skillcask.app`,
and `/usr/local/bin/skillcask`, a symbolic link to that app's `Contents/Helpers/skillcask`: the
package holds no second copy of the CLI, D69).
