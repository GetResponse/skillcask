# AutoPkg recipes

Two [AutoPkg](https://github.com/autopkg/autopkg) recipes for the installer package every release
from VNEXT on attaches, `Skillcask-X.Y.Z-macos-universal.pkg`. The package puts `Skillcask.app` in
`/Applications` and `skillcask` in `/usr/local/bin`; it is signed with a Developer ID Installer
certificate, notarized and stapled.

| Recipe | What it does |
|---|---|
| `Skillcask.download` | Finds the newest release that has the package, downloads it and verifies who signed it |
| `Skillcask.pkg` | The same, then copies the package, unchanged, to `Skillcask-X.Y.Z.pkg` in the recipe cache and sets `pkg_path` |

Both use only AutoPkg's own processors and need AutoPkg 2.3 or newer.

## Use

```sh
autopkg repo-add GetResponse/skillcask
autopkg make-override Skillcask.pkg
autopkg run -v Skillcask.pkg
```

`repo-add` clones this whole repository; AutoPkg reads only this directory. The run leaves
`~/Library/AutoPkg/Cache/local.pkg.Skillcask/Skillcask-X.Y.Z.pkg`.

Importing the package into your management system is your step: write a recipe with
`ParentRecipe: com.github.getresponse.pkg.Skillcask` that takes `%pkg_path%` and `%version%`.

## Pre-releases

The recipes skip pre-releases. To pilot a release candidate:

```sh
autopkg run -v -k PRERELEASE=yes Skillcask.pkg
```

or set `PRERELEASE` in the override. Any non-empty value turns it on, `no` and `false` too; leave
it empty to turn it off. With it on, AutoPkg takes the newest release, stable or not.

## What the recipes verify

Only the signer: `pkgutil --check-signature` must pass, and the certificate chain must be exactly
the three names in `Skillcask.download.recipe.yaml`. They do not check notarization or the
`.sha256` file next to the package, and `autopkg run --check` stops before the signature check.
By hand:

```sh
pkg=~/Library/AutoPkg/Cache/local.pkg.Skillcask/Skillcask-X.Y.Z.pkg
spctl --assess --type install -vv "$pkg"   # accepted, source=Notarized Developer ID
xcrun stapler validate "$pkg"              # the stapled ticket; needs Xcode or the Command Line Tools
shasum -a 256 "$pkg"                       # the same hash as in:
curl -fsSL https://github.com/GetResponse/skillcask/releases/download/vX.Y.Z/Skillcask-X.Y.Z-macos-universal.pkg.sha256
```

## A release without its package

A release is published first; the signing job attaches the package later. In between, AutoPkg
returns the package of the previous release: it takes the newest release that has one. Run it
again later.

## Changes to these files

An override stores a hash of both recipe files, so any edit, even to a comment, makes
`autopkg run` fail trust verification for every administrator until they review the change and
run `autopkg update-trust-info Skillcask.pkg`. The identifiers and the input names `NAME` and
`PRERELEASE` therefore stay as they are, and new behaviour comes as a new recipe, not as an edit.

`python3 -I autopkg/test_recipes.py` checks which release assets the download recipe selects;
`.github/workflows/autopkg.yml` runs it, audits both recipes and runs them with AutoPkg.
