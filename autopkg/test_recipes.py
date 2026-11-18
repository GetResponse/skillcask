#!/usr/bin/env python3
"""Check which release assets the download recipe's asset_regex selects.

    python3 -I autopkg/test_recipes.py [ASSET_NAME ...]
    python3 -I autopkg/test_recipes.py --authority-names

Every ASSET_NAME given must match too, for example the file name of a package just built.
Standard library only. The regex is read from the recipe, so there is one copy of it. AutoPkg
applies it with re.match to every asset name of a release and takes the first match, so exactly
the installer packages may match. Run by AutoPkg's own Python, which has PyYAML, it also checks
that the lines read here are the values a YAML parser gives.

--authority-names prints the recipe's expected_authority_names, one per line, and checks nothing
else: the release job compares them with the chain `pkgutil --check-signature` prints for the
package it is about to attach.
"""

import pathlib
import re
import sys

RECIPE = pathlib.Path(__file__).resolve().parent / "Skillcask.download.recipe.yaml"

MATCH = [
    "Skillcask-0.14.0-macos-universal.pkg",
    "Skillcask-0.14.0-rc.1-macos-universal.pkg",
    "Skillcask-0.14.0-rc-1-macos-universal.pkg",
    "Skillcask-1.2.30-macos-universal.pkg",
]

NO_MATCH = [
    "Skillcask-0.14.0-macos-universal.pkg.sha256",
    "Skillcask-0.14.0-rc.1-macos-universal.pkg.sha256",
    "Skillcask-0.13.0-macos-universal.zip",
    "Skillcask-0.13.0-macos-universal.zip.sha256",
    "skillcask-aarch64-apple-darwin.tar.xz",
    "skillcask-aarch64-apple-darwin.tar.xz.sha256",
    "skillcask-x86_64-apple-darwin.tar.xz",
    "skillcask-x86_64-apple-darwin.tar.xz.sha256",
    "skillcask-aarch64-unknown-linux-gnu.tar.xz",
    "skillcask-x86_64-unknown-linux-gnu.tar.xz",
    "skillcask-x86_64-unknown-linux-musl.tar.xz",
    "skillcask-x86_64-pc-windows-msvc.zip",
    "skillcask-installer.sh",
    "skillcask-installer.ps1",
    "skillcask-app-installer.sh",
    "skillcask-npm-package.tar.gz",
    "skillcask.rb",
    "dist-manifest.json",
    "sha256.sum",
    "source.tar.gz",
    "source.tar.gz.sha256",
    # Not release assets today: near misses the anchors and the character classes must refuse.
    "skillcask-0.14.0-macos-universal.pkg",
    "Skillcask-0.14-macos-universal.pkg",
    "Skillcask-0.14.0-macos-arm64.pkg",
    "Skillcask-0.14.0-macos-universal.pkg.zip",
    "old-Skillcask-0.14.0-macos-universal.pkg",
    "Skillcask-0.14.0-macos-universalxpkg",
    "Skillcask-0x14x0-macos-universal.pkg",
    "Skillcask-0.14.0+b1-macos-universal.pkg",
    "Skillcask-0.14.0-rc+b1-macos-universal.pkg",
    "Skillcask-0.14.0-rc-1-macos-universal.pkg.sha256",
    "Skillcask-0.14.0-rc-1-macos-universal.zip",
]


def asset_regex() -> str:
    """Return the recipe's asset_regex.

    The value must be on one line in single quotes with no quote inside: YAML then takes the
    characters between the quotes as they are, backslashes included.
    """
    lines = [
        line
        for line in RECIPE.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("asset_regex:")
    ]
    if len(lines) != 1:
        sys.exit(f"{RECIPE.name}: expected one asset_regex line, found {len(lines)}")
    found = re.fullmatch(r"\s+asset_regex: '([^']+)'", lines[0])
    if not found:
        sys.exit(f"{RECIPE.name}: asset_regex must be one single-quoted line: {lines[0]!r}")
    return found.group(1)


def authority_names() -> list:
    """Return the recipe's expected_authority_names.

    The list must follow `expected_authority_names:` directly, one item per line, each either in
    single quotes with no quote inside or a plain scalar of letters, digits, spaces, dots and
    parentheses: YAML then takes both as they are.
    """
    lines = RECIPE.read_text(encoding="utf-8").splitlines()
    starts = [i for i, line in enumerate(lines) if line.strip() == "expected_authority_names:"]
    if len(starts) != 1:
        sys.exit(f"{RECIPE.name}: expected one expected_authority_names line, found {len(starts)}")
    names = []
    for line in lines[starts[0] + 1 :]:
        if not line.strip().startswith("- "):
            break
        found = re.fullmatch(r"\s+- (?:'([^']+)'|([A-Za-z0-9][A-Za-z0-9 .()]*[A-Za-z0-9)]))", line)
        if not found:
            sys.exit(f"{RECIPE.name}: an authority name must be one single-quoted or plain line: {line!r}")
        names.append(found.group(1) or found.group(2))
    if not names:
        sys.exit(f"{RECIPE.name}: expected_authority_names lists no name")
    return names


def parsed_step_argument(processor: str, argument: str):
    """Return an argument of the recipe's one step of processor as PyYAML reads it.

    None where PyYAML is missing.
    """
    try:
        import yaml
    except ImportError:
        return None
    recipe = yaml.safe_load(RECIPE.read_text(encoding="utf-8"))
    values = [
        step["Arguments"][argument] for step in recipe["Process"] if step["Processor"] == processor
    ]
    if len(values) != 1:
        sys.exit(f"{RECIPE.name}: expected one {processor} step")
    return values[0]


def main() -> None:
    if sys.argv[1:] == ["--authority-names"]:
        print("\n".join(authority_names()))
        return

    regex = asset_regex()
    print(f"asset_regex: {regex}")
    if not regex.endswith("$"):
        sys.exit("asset_regex must end in $: re.match anchors only the start")

    names = authority_names()
    print(f"expected_authority_names: {names}")
    if len(names) != 3 or not names[0].startswith("Developer ID Installer: "):
        sys.exit("expected_authority_names must be the three names of a Developer ID Installer chain")

    parsed = parsed_step_argument("GitHubReleasesInfoProvider", "asset_regex")
    parsed_names = parsed_step_argument("CodeSignatureVerifier", "expected_authority_names")
    if parsed is None:
        print("PyYAML not available: skipped the parser cross-check")
    elif parsed != regex:
        sys.exit(f"a YAML parser reads asset_regex as {parsed!r}")
    elif parsed_names != names:
        sys.exit(f"a YAML parser reads expected_authority_names as {parsed_names!r}")
    else:
        print("PyYAML reads the same value")

    failures = []
    built = sys.argv[1:]
    for name, expected in [(n, True) for n in MATCH + built] + [(n, False) for n in NO_MATCH]:
        matched = re.match(regex, name) is not None
        ok = matched == expected
        print(f"{'ok  ' if ok else 'FAIL'} {'match   ' if matched else 'no match'} {name!r}")
        if not ok:
            failures.append(name)
    if failures:
        sys.exit(f"{len(failures)} asset name(s) matched wrongly: {failures}")
    print(f"{len(MATCH + built)} names match, {len(NO_MATCH)} do not")


if __name__ == "__main__":
    main()
