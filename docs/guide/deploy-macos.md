# Deploy on managed Macs

From 0.14.0 on, every release also has one installer package for Macs that device management (Jamf
and others) installs software on: `Skillcask-X.Y.Z-macos-universal.pkg`, with
`Skillcask-X.Y.Z-macos-universal.pkg.sha256` next to it. It is for administrators. On your own Mac,
use Homebrew or the installer scripts ([Install](install.md)).

## What the package installs

| Component (receipt) | Installs | Owner |
|---|---|---|
| `com.getresponse.skillcask.pkg.app` | `/Applications/Skillcask.app` | `root:wheel` |
| `com.getresponse.skillcask.pkg.cli` | `/usr/local/bin/skillcask`, a symbolic link to `/Applications/Skillcask.app/Contents/Helpers/skillcask` | `root:wheel` |

- The app is the signed, notarized and stapled app of the release zip. The package is another
  container for that released build, not a build of its own: the app is the one the cask
  `skillcask-app` installs, and its CLI, `Contents/Helpers/skillcask`, is universal and Developer
  ID signed, the same release as the formula `skillcask`, which installs a binary for one
  architecture.
- `/usr/local/bin/skillcask` is a link to that CLI, not a second file. The command on `PATH` is
  therefore always the CLI of the app in `/Applications`, at the app's version, whatever replaced
  the app last. If the app is deleted or moved, the link leads nowhere and the command fails
  until the package is installed again. The install replaces a file or a link of that name that
  is already there.
- The price of the link: it runs whatever app is in `/Applications`. Once a user-owned copy
  replaces the deployed app (the cask, the release zip, the app's installer script),
  `/usr/local/bin/skillcask` runs a file that user can write. So no management script may run
  the CLI as root: run it as the logged-in user, and read versions without running it
  ([Inventory](#inventory)).
- One package for Apple silicon and Intel, macOS 14 or later. It installs for the whole machine
  only.
- It has no install scripts and writes nothing into user homes. It does not quit a running app,
  add a login item or change `PATH` (`/usr/local/bin` is in macOS's `/etc/paths`).
- The app always goes to `/Applications`, also when a copy lies elsewhere, and the package does
  not compare versions: an older package installs over a newer app. CI installs the
  package over a copy of the app whose version is set higher and checks that the app is replaced;
  a rollback over a newer package's receipts has not been tried yet.
- The package itself is signed with a Developer ID Installer certificate, notarized and stapled.
  Its identifier is `com.getresponse.skillcask.pkg`; the receipts are the two components'.

It ships no configuration. The machine-wide `config.toml` [below](#machine-wide-configtoml) is
yours to deploy.

## Verify before you deploy

Device management installs a package as root, usually from a file without the quarantine flag, so
do not count on Gatekeeper checking it on the way in. Check it once yourself, in the folder that
holds both files:

```sh
shasum -a 256 -c Skillcask-X.Y.Z-macos-universal.pkg.sha256
pkgutil --check-signature Skillcask-X.Y.Z-macos-universal.pkg
spctl --assess --type install -vv Skillcask-X.Y.Z-macos-universal.pkg
xcrun stapler validate Skillcask-X.Y.Z-macos-universal.pkg
```

- `pkgutil --check-signature` must say `Status: signed by a developer certificate issued by Apple
  for distribution` and `Notarization: trusted by the Apple notary service`, with the chain
  `Developer ID Installer: … (<team id>)`, `Developer ID Certification Authority`,
  `Apple Root CA`.
- `spctl` must print `accepted` and `source=Notarized Developer ID`.
- `stapler validate` confirms that the notarization ticket is stapled to the package, so a Mac can
  confirm the notarization without asking Apple's servers. `xcrun stapler` needs Xcode or the
  Command Line Tools on the Mac you check on.
- The team id in parentheses must be the one that signed the app. Read it from the app of the
  release zip, or from a copy Homebrew installed:

  ```sh
  codesign -dv /Applications/Skillcask.app 2>&1 | grep TeamIdentifier
  ```

The checksum comes from the same release as the package; the signature and the notarization are
the real check.

To see what it would install without installing it:

```sh
pkgutil --expand Skillcask-X.Y.Z-macos-universal.pkg expanded
grep -o 'install-location="[^"]*"' expanded/*.pkg/PackageInfo   # /Applications and /usr/local/bin
for c in expanded/*.pkg; do lsbom -p MUGf "$c/Bom"; done        # mode, owner, group, path
find expanded -name Scripts                                     # prints nothing: no scripts
```

An entry named `._<name>` in the `lsbom` listing carries the extended attributes of `<name>` next
to it: Installer applies them to that file and writes no `._` file. `pkgutil --payload-files`
lists one component only, so it does not show both. With a checkout of this repository,
`macos/Scripts/check-pkg.sh <pkg>` makes these checks and more, reading the package only.

## Deploy

Upload the package as it is and install it with a policy; do not repackage it, which would drop
the signature and the notarization. The release job installs each package once on its macOS runner
before attaching it. To do the same by hand on a test Mac:

```sh
sudo installer -pkg Skillcask-X.Y.Z-macos-universal.pkg -target /
```

An install sent as a device-management command, or during enrolment, is not tested.

Remove a Homebrew install first: the package and Homebrew's `skillcask` and `skillcask-app` do
not go together on one Mac ([below](#next-to-homebrew-and-other-installs)). Then deploy the
package, then the configuration.

## Machine-wide config.toml

skillcask reads `/Library/Application Support/skillcask/config.toml` under every user's own
`config.toml`. No environment variable moves it. The package works without the file; deploying it
with `[updates] managed` is recommended, since that is where you tell people who updates skillcask
and where to ask:

```toml
[updates]
managed = "IT installs skillcask updates a few days after each release. Nothing to do here."
```

Without it, when a newer release exists:

- `skillcask self-update` recognises the package when three things hold: it runs as the CLI
  inside `Skillcask.app` (`/usr/local/bin/skillcask` is a link to it), the receipt
  `com.getresponse.skillcask.pkg.app` is on the Mac, and root owns that CLI, as Installer leaves
  it. It then exits 1 and downloads and installs nothing:

  ```
  error: skillcask X -> Y: installed with the macOS installer package; your administrator deploys updates
    hint: the package Skillcask-Y-macos-universal.pkg is on https://github.com/GetResponse/skillcask/releases/tag/vY
  ```

  The words are skillcask's and the same on every Mac, also for a person who installed the
  package by hand. The hint names the release page, not the file's URL, since the package can
  trail its release ([Limits](#limits)).
- The app's update sheet does not know the package. It says "Installed from a download" and,
  under "How to update", to download `Skillcask-Y-macos-universal.zip` from the release page and
  drag the app into Applications. While a `Caskroom/skillcask-app` folder left by Homebrew
  exists, it says "Installed with Homebrew" and shows
  `brew update && brew upgrade skillcask skillcask-app` instead. Neither is how a deployed Mac is
  updated.

So `managed` is recommended for the CLI's message and is the only way to change what the app's
sheet says. With it set, your text comes first everywhere, whatever skillcask detects:

- `self-update` exits 1 with `error: skillcask X -> Y: updates are managed by your organisation`
  and your text as the hint. It downloads and runs nothing.
- `self-check` prints `note: updates are managed by your organisation: <text>` with its release
  line, and `--json` carries the text as `managed`.
- The app's sheet shows the text under "Updates are managed by your organisation" in place of
  those steps, with no command to copy. It keeps the line that says how the app was installed
  and the buttons Skip This Version, Remind Me Tomorrow and Open Release Page. The app takes the
  text from its last `self-check`.
- The machine-wide text wins over a `managed` in the user's own `config.toml`.

With no newer release, `self-update` prints only `skillcask X is the latest` and exits 0, with or
without `managed`.

`self-check` and the app learn of a release as soon as it is public, before you have deployed it.
Say so in the text: who installs updates, how long after a release, and where to ask.

Policy for every project (`allow-sources`, `deny-packages`, `enforce`, …) goes in the same file:
[Policy](policy.md).

### Owner and mode

Run as root, as a device-management script does:

```sh
mkdir -p "/Library/Application Support/skillcask"
chown root:wheel "/Library/Application Support/skillcask"
chmod 755 "/Library/Application Support/skillcask"
install -o root -g wheel -m 644 config.toml "/Library/Application Support/skillcask/config.toml"
```

- skillcask checks the file only: its owner must be root, and neither group nor others may write
  it. Otherwise every run warns `/Library/Application Support/skillcask/config.toml: ignored, it is
  not owned by root` (or `ignored, group or others may write it`) and reads no machine-wide file.
- It does not check the folder. Whoever can write the folder can delete or replace the file, so
  keep it `root:wheel`, mode 755.
- Users must be able to read the file. skillcask runs as the user: a file or folder it cannot read
  is an error, not a missing file.

### A mistake in the file stops skillcask

The file is read strictly. A TOML syntax error, a table other than `[policy]`, `[agents]`,
`[search]` and `[updates]`, an unknown key in one of them, or a value of the wrong type (an empty
`managed` too) is an error that names the file:

```
error: /Library/Application Support/skillcask/config.toml: only [policy], [agents], [search] and [updates] are read here, found update
error: /Library/Application Support/skillcask/config.toml: updates.manage is not read here, only updates.managed
error: /Library/Application Support/skillcask/config.toml: updates.managed must be a non-empty string
```

- Every command that reads the policy then exits 1 for every user, among them `install`, `add`,
  `update`, `status`, `doctor` and `config`. The app runs those commands and shows the same error.
- A few commands that need no settings, such as `--version`, `--help`, `auth` and `validate`, do
  not read the file.
- `self-check` still reports the release, after `warning: updates.managed unknown: …`, without the
  managed text.
- `self-update` fails with that error once a newer release exists; before that it prints
  `is the latest`.

An older skillcask refuses tables and keys it does not know. Deploy the package first and the
file second, and write the file for the oldest version still on your Macs. The machine-wide file
and `[updates] managed` are read from 0.13.0 on; every release with a package is newer.

### Check a file before you deploy it

The user's `config.toml` goes through the same parser, so a candidate can be checked as one,
without root and without touching the real paths. Check it with the oldest skillcask still
deployed: a newer one accepts tables and keys that an older one refuses. The binary of that
release's archive will do ([Install](install.md)); any 0.13.0 or later reads these files.

```sh
skillcask=/usr/local/bin/skillcask                    # the oldest version still deployed
dir=$(mktemp -d)
cp config.toml "$dir/config.toml"
SKILLCASK_HOME="$dir" "$skillcask" -g config          # exit 0 and the settings: it parses
SKILLCASK_HOME="$dir" "$skillcask" self-check         # ends with the managed text
rm -r "$dir"
```

`-g config` prints every policy key with its value and writes nothing; a mistake exits 1 with the
messages above. `self-check` makes its one request to GitHub.

What this proves: the syntax, the tables, the keys and the values. What it does not:

- the owner, the mode and the path, which only the deployed file has. After deploying, run
  `skillcask -g config` and `skillcask self-check` as a standard user: no `ignored` warning, the
  policy keys you set show `system config.toml` or `system config.toml, enforced`, and
  `self-check` ends with your text;
- how the file meets a user's own `config.toml`: a user file that loosens a key you enforce fails
  that user's commands with a message naming both files ([Policy](policy.md));
- a target that names the same folder as a project's own `[agents] local`. `-g config` checks the
  targets as an empty project sees them; only that project's commands see the clash, and they fail
  with `error: skills.toml: agents.local "<folder>" cannot also be a target`.

Run it on a Mac that has no machine-wide file yet, and with no `SKILLCASK_*` policy variables set:
otherwise the candidate is read as a user file over the deployed one, and through the
environment.

## Updates and rollback

Deploy the newer package: it replaces the app, and with it the CLI, which is one file inside the
app; the link in `/usr/local/bin` is written again and leads to the new one. Nothing quits a
running app, and an install under a running app is not tested: expect it to keep its old version
until it is reopened, while the CLI inside its bundle is already the new one. Quit the app first,
or deploy when it is not running.

Whatever else replaces `/Applications/Skillcask.app` later (the release zip, the app's installer
script) changes the command in `/usr/local/bin` with it, since the link leads into the app. The
receipts then still name the version the package installed. `self-update` goes by the owner of
the CLI: a copy a user put there is not root's, so it is no longer taken for the package's.

To go back, deploy the older package. The package is built for that: it does not compare
versions, so the older package should downgrade the app and its CLI. CI installs the
package over a copy of the app whose version is set higher and checks that the app is replaced. A
rollback over a newer package's receipts has not been tried yet, neither on a runner nor
through device management. After a rollback the machine-wide `config.toml` must suit the older
binary ([above](#a-mistake-in-the-file-stops-skillcask)).

Deploy the latest release rather than keeping old packages for later ([Limits](#limits)).

## Inventory

- The app reports its version like any other app (`CFBundleShortVersionString`, `X.Y.Z`).
- Receipts:

  ```sh
  pkgutil --pkgs='com\.getresponse\.skillcask\.pkg\..*'
  pkgutil --pkg-info com.getresponse.skillcask.pkg.cli
  pkgutil --files com.getresponse.skillcask.pkg.app
  ```

- For an extension attribute or a script, which run as root: read the version, do not run
  `skillcask --version` ([why](#what-the-package-installs)).

  ```sh
  # what is there now: X.Y.Z, the app's version and its CLI's
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Skillcask.app/Contents/Info.plist
  # what was deployed: the line `version: X.Y.Z`
  pkgutil --pkg-info com.getresponse.skillcask.pkg.app
  ```

  The two differ once something else replaced the app; the first fails when the app is gone.
  `readlink /usr/local/bin/skillcask` prints
  `/Applications/Skillcask.app/Contents/Helpers/skillcask` while the link is the package's.

## Next to Homebrew and other installs

The package and a Homebrew install exclude each other: on one Mac, use either the package or the
formula `skillcask` and the cask `skillcask-app`, not both. They write the same paths, and each
undoes the other. Uninstall Homebrew's before the package is deployed, as the user who runs
Homebrew (`brew` refuses to run as root):

```sh
brew uninstall --cask skillcask-app
brew uninstall skillcask
```

- **Cask.** It puts a user-owned `Skillcask.app` at the same path, `/Applications/Skillcask.app`,
  and keeps a `Caskroom/skillcask-app` folder. Left in place, a later
  `brew uninstall --cask skillcask-app` removes the app at that path, by then the deployed one,
  and with it what `/usr/local/bin/skillcask` runs. While the folder exists the app's update
  sheet takes the app for a Homebrew install and, without `managed`, shows the `brew` command;
  `self-update` does not, as long as root owns the CLI. `brew uninstall --cask` removes the
  folder.
- **Formula on Intel.** Homebrew's prefix is `/usr/local`, so the formula's link
  `/usr/local/bin/skillcask` (into `/usr/local/Cellar`) and the package's are the same path. The
  install replaces Homebrew's link with the package's, and Homebrew's copy stays in the Cellar,
  unlinked. The next `brew upgrade skillcask` or `brew link skillcask` then reports
  `Could not symlink bin/skillcask`, `Target /usr/local/bin/skillcask`,
  `already exists. You may want to remove it:`, and leaves the formula unlinked. The fixes it
  prints (`rm '/usr/local/bin/skillcask'`, `brew link --overwrite skillcask`) remove the
  package's link. Once the app is gone and the link leads nowhere, Homebrew replaces the link
  with its own without a message. Where Homebrew owns
  `/usr/local/bin`, its owner can replace or delete the link without root. The package is built,
  and tested in CI, to leave that folder's owner and mode as they are.
- **Formula on Apple silicon.** `/opt/homebrew/bin` comes before `/usr/local/bin` once
  `brew shellenv` is set up, so a leftover formula hides the deployed CLI in the terminal.
- **Installer script, Cargo, npm, bun.** Those copies live outside the package's paths
  (`~/.cargo/bin`, a global `node_modules`) and win wherever their folder comes first in `PATH`.

To find them in a user's Terminal:

```sh
which -a skillcask
ls -d /opt/homebrew/Caskroom/skillcask-app /usr/local/Caskroom/skillcask-app \
      /opt/homebrew/Cellar/skillcask /usr/local/Cellar/skillcask ~/.cargo/bin/skillcask 2>/dev/null
```

A management script runs as root, without the user's home or `PATH`; in `sh` or `bash` it can look
at the fixed paths and every home:

```sh
ls -d /opt/homebrew/Caskroom/skillcask-app /usr/local/Caskroom/skillcask-app \
      /opt/homebrew/Cellar/skillcask /usr/local/Cellar/skillcask /Users/*/.cargo/bin/skillcask 2>/dev/null
ls -l /usr/local/bin/skillcask 2>/dev/null     # a link into Cellar is Homebrew's
```

The app runs its own CLI unless its Settings name another binary, so `PATH` does not change what
the app does. A script that must run the deployed CLI runs it as the logged-in user, never as
root ([why](#what-the-package-installs)), and calls `/usr/local/bin/skillcask` by its full path.

## Uninstall

The package has no uninstaller. Remove the app and the link, then both receipts.

First check that `/usr/local/bin/skillcask` is still the package's: the receipt exists, and the
entry is a link to the app's CLI. Otherwise another install (Homebrew on Intel, whose link leads
into the Cellar) put its own there; leave it to that install.

```sh
pkgutil --pkg-info com.getresponse.skillcask.pkg.cli     # location: usr/local/bin
readlink /usr/local/bin/skillcask     # /Applications/Skillcask.app/Contents/Helpers/skillcask
```

Then, as root, quit the app (`pkill -x Skillcask` ends it for every user) and remove both:

```sh
rm -rf /Applications/Skillcask.app
rm -f /usr/local/bin/skillcask                      # only when the check above said so
pkgutil --forget com.getresponse.skillcask.pkg.app
pkgutil --forget com.getresponse.skillcask.pkg.cli
rm -rf "/Library/Application Support/skillcask"      # the machine-wide config, if you deployed one
```

Removing the app alone leaves a link that leads nowhere, and `pkgutil --forget` discards a receipt
only; it removes no file. So all four steps are needed. While the receipt
`com.getresponse.skillcask.pkg.app` is left, `self-update` takes a later `Skillcask.app` for the
package's whenever root owns its CLI, for example one that root copied into `/Applications`.

What stays, per user, because the package never wrote it:

| Path | What |
|---|---|
| `~/.config/skillcask` (`$XDG_CONFIG_HOME/skillcask`, `SKILLCASK_HOME`) | personal `skills.toml`, `skills.lock`, `config.toml`, `auth.json`, `adopted/` |
| `~/.agents/skills`, links in `~/.claude/skills` and other agent folders | personal skills |
| `skills.toml`, `skills.lock`, `.agents/skills` in each project | project skills |
| `~/Library/Preferences/io.github.puniserv.skillcask.plist`, `~/Library/Saved Application State/io.github.puniserv.skillcask.savedState` | the app's settings and window state |
| the Keychain | tokens saved with `skillcask auth set` |

## Limits

- **The package can trail the release, or be missing.** A separate job attaches it after the
  release and the app zip are public, and waits for a reviewer. If that job fails, the release
  stands without a package until it is rerun. Check that the release you want has the `.pkg`: a
  tool that takes the newest release with a matching file picks the release before it meanwhile.
  Releases before 0.14.0 have none.
- **Pre-releases.** `-rc` tags carry a package too. Deploy only releases that are not marked
  pre-release.
- **No recipes yet.** AutoPkg recipes are not published.
- **Old packages.** The Developer ID Installer certificate that signs a package expires, and
  Apple's own pages disagree on whether a package still installs after that. Deploy the latest
  release; do not count on an old package installing later.
- **macOS 13 and older.** The package names macOS 14 as its minimum, for the app and the CLI
  alike; nothing older is tested.
- **A linked `/usr/local`.** A Mac where `/usr/local` or `/usr/local/bin` is itself a symbolic
  link is not tested.
- **What it does not set up.** No `config.toml`, policy, registry token or skill; no `PATH` entry
  beyond the link in `/usr/local/bin`. The app's daily update check stays off until each user
  says yes once.
