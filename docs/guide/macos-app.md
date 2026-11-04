# macOS app

`macos/` holds a SwiftUI app for macOS 14+ over the CLI (D35): open My Skills (the `-g` scope) or a
project folder, see each skill's state, updates and audit findings, read its SKILL.md and diffs,
and run `add` (also `--adopt`), `update`, `remove`, `install` and `doctor --fix`; its Settings
change every key `skillcask -g config` lists. It has no package logic of its own: it runs the
`skillcask` binary, 0.9.4 or newer, and reads its `--json` output.

Install it with Homebrew, then open it from Applications or with `skillcask app`. The cask depends
on the formula; name both, since Homebrew loads from a third-party tap only what it was asked for
or what `brew trust` lists:

```sh
brew install getresponse/tap/skillcask getresponse/tap/skillcask-app
```

Every release also has `Skillcask-X.Y.Z-macos-universal.zip`, signed with a Developer ID and
notarized (D50): unzip it into `/Applications`.

The app tells you about a newer release but installs nothing ([Update](install.md#update)). Its app menu
has Check for Updates…, which runs `skillcask self-check`; it checks daily only after you say yes
once (it asks in the sidebar; Settings › Updates switches it). A newer version gets a card and a
sheet with the Homebrew command to copy, or the release page for a download (D51).

`macos/bundle.sh` builds a universal `Skillcask.app` that carries its own CLI at
`Contents/Helpers/skillcask`. Run outside a bundle (`swift run` from `macos/`), the app uses the
path set in its Settings, else looks on `PATH`, in `/opt/homebrew/bin`, `/usr/local/bin` and
`~/.cargo/bin`. Building it needs Xcode 26.x with Swift 6.3 or newer, not only the Command Line
Tools. Building, signing, Gatekeeper, tests and renders: [macos/README.md](../../macos/README.md).
