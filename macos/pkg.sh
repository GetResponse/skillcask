#!/bin/sh
# Wraps a built Skillcask.app and the CLI inside it into one installer package, for Macs that get
# their software from device management (Jamf and similar), where a package is what gets deployed.
#
#   ./pkg.sh                                      # packages .build/Skillcask.app, unsigned
#   SKILLCASK_APP=/path/to/Skillcask.app ./pkg.sh # packages another build, e.g. the released zip's
#   INSTALLER_IDENTITY="Developer ID Installer: Name (TEAMID)" [INSTALLER_KEYCHAIN=/path] ./pkg.sh
#
# INSTALLER_IDENTITY is the certificate's full common name, ending in the team id in parentheses
# (`security find-identity -v` prints it). The team is read from it: a value that does not end in
# `(TEAMID)`, ten capital letters or digits, is refused, and so is a SHA-1 hash.
#
# Output (git-ignored):
#   .build/Skillcask-<version>-macos-universal.pkg
#     /Applications/Skillcask.app   component com.getresponse.skillcask.pkg.app
#     /usr/local/bin/skillcask      component com.getresponse.skillcask.pkg.cli
#
# The product identifier com.getresponse.skillcask.pkg, the two component identifiers, the
# file name pattern and the two install paths are a permanent contract with administrators:
# receipts, inventory rules and download recipes (AutoPkg) name them. Do not change them. The
# package identifiers sit under the organisation's reverse-domain namespace, com.getresponse, apart
# from the app's bundle identifier io.github.puniserv.skillcask, which is the app's own and is only
# checked here.
#
# The input is an app `bundle.sh` built (or the released one); nothing is built or signed here.
# The version is the app's CFBundleShortVersionString. The CLI in /usr/local/bin is a plain copy of
# the app's Contents/Helpers/skillcask, byte for byte, so it keeps the signature it has. The package
# carries no scripts. Each component is rooted at its install location, so the payload has no
# entries for /usr or /usr/local. It does have one for the install location itself (`.`, root:wheel
# 755): that an install leaves the owner and mode of an existing /Applications and /usr/local/bin
# as they were is what `Scripts/check-pkg.sh --install` asserts.
#
# Unsigned by default: such a package is for testing (Scripts/check-pkg.sh, CI's macos-pkg job).
# With INSTALLER_IDENTITY the product is signed and timestamped, and the app must already be signed
# with a Developer ID of the same team, notarized and stapled. Notarizing the package itself
# (`xcrun notarytool submit … --wait`, then `xcrun stapler staple`) is not done here.
set -eu
umask 022
# Relative paths are relative to where the script was started, not to macos/.
case "${SKILLCASK_APP:-}" in
"" | /*) ;;
*) SKILLCASK_APP=$(pwd)/$SKILLCASK_APP ;;
esac
case "${INSTALLER_KEYCHAIN:-}" in
"" | /*) ;;
*) INSTALLER_KEYCHAIN=$(pwd)/$INSTALLER_KEYCHAIN ;;
esac
cd "$(dirname "$0")"

app=${SKILLCASK_APP:-.build/Skillcask.app}
identity=${INSTALLER_IDENTITY:-}
bundle_id=io.github.puniserv.skillcask
pkg_id=com.getresponse.skillcask.pkg
plistbuddy=/usr/libexec/PlistBuddy

fail() {
    echo "pkg.sh: $*" >&2
    exit 1
}

# Whether $1 holds both slices (this lipo checks one -verify_arch at a time).
universal() {
    lipo "$1" -verify_arch arm64 2>/dev/null && lipo "$1" -verify_arch x86_64 2>/dev/null
}

# Fails unless $1 carries a notarizable Developer ID signature of team $team.
developer_id_signed() {
    info=$(codesign -dvv "$1" 2>&1) || fail "codesign cannot read the signature of $1"
    printf '%s\n' "$info" | grep -q '^Authority=Developer ID Application: ' ||
        fail "$1 is not signed with a Developer ID Application certificate"
    printf '%s\n' "$info" | grep -qx "TeamIdentifier=$team" ||
        fail "$1 is not signed by team $team, the team of INSTALLER_IDENTITY"
    printf '%s\n' "$info" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\(([a-z-]+,)*runtime(,[a-z-]+)*\)' ||
        fail "$1 is signed without the hardened runtime"
    printf '%s\n' "$info" | grep -q '^Timestamp=' || fail "$1 is signed without a secure timestamp"
}

# 0. The input: the app this package is named after, with a matching universal CLI inside.
helper=$app/Contents/Helpers/skillcask
[ -f "$app/Contents/Info.plist" ] || fail "no app at $app (run ./bundle.sh or set SKILLCASK_APP)"
[ "$(basename "$app")" = Skillcask.app ] || fail "$app is not named Skillcask.app"
found_id=$($plistbuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") ||
    fail "$app has no CFBundleIdentifier"
[ "$found_id" = "$bundle_id" ] || fail "$app has the bundle identifier $found_id, not $bundle_id"
version=$($plistbuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") ||
    fail "$app has no CFBundleShortVersionString"
# The version goes into file names and XML as it is, and administrators' download recipes match the
# asset name with a fixed pattern: a package with a version outside X.Y.Z[-<pre-release>] is one they
# never pick up. (grep -x matches per line, so a version with a line break is refused first.)
case "$version" in
*"
"*) fail "$app has a version with a line break" ;;
esac
printf '%s\n' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?' ||
    fail "$app has the version '$version', not X.Y.Z or X.Y.Z-<pre-release> (digits, letters, '.', '-')"
min_os=$($plistbuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist") ||
    fail "$app has no LSMinimumSystemVersion"
case "$min_os" in
*[!0-9.]* | "") fail "$app has the LSMinimumSystemVersion '$min_os'" ;;
esac
[ -f "$helper" ] && [ -x "$helper" ] || fail "no CLI at $helper"
universal "$helper" || fail "$helper is not universal ($(lipo -archs "$helper"))"
cli_version=$("$helper" --version) || fail "$helper --version failed"
case "$cli_version" in
"skillcask $version" | "skillcask $version "*) ;;
*) fail "the CLI in the app is '$cli_version', the app is $version" ;;
esac
codesign --verify --strict "$app" || fail "$app does not pass codesign --verify --strict"

if [ -n "$identity" ]; then
    # A package signed for distribution must hold an app Gatekeeper accepts offline.
    team=$(printf '%s\n' "$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
    [ -n "$team" ] || fail "INSTALLER_IDENTITY must end with the team id in parentheses: $identity"
    developer_id_signed "$app"
    developer_id_signed "$helper"
    xcrun stapler validate "$app" >/dev/null || fail "$app has no stapled notarization ticket"
fi

# 1. Staging: one root per component, each rooted at its install location. The mode of a root is
# archived as the payload's `.`, so it is set, not left to mktemp.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -m 755 "$stage/app-root" "$stage/cli-root" "$stage/packages"
ditto "$app" "$stage/app-root/Skillcask.app"
cp "$helper" "$stage/cli-root/skillcask"
chmod 755 "$stage/cli-root/skillcask"
# pkgbuild archives extended attributes: a quarantine flag (an app unzipped from a download has one)
# would be installed with the app. The signatures live in the files, not in attributes. Only
# com.apple.provenance may stay: the system sets it and does not let it be removed.
xattr -cr "$stage/app-root" "$stage/cli-root"
left=$(xattr -r "$stage/app-root" "$stage/cli-root" | grep -v ': com\.apple\.provenance$' | head -n 1 || true)
[ -z "$left" ] || fail "could not clear an extended attribute from the staged copy: ${left#"$stage"/*/}"
cmp -s "$helper" "$stage/cli-root/skillcask" || fail "the staged CLI differs from $helper"
codesign --verify --strict "$stage/app-root/Skillcask.app" || fail "the staged app does not verify"
codesign --verify --strict "$stage/cli-root/skillcask" || fail "the staged CLI does not verify"
# The modes are installed as they are (ownership becomes root:wheel): every user must be able to
# read each file, only root to write it.
loose=$(find "$stage/app-root" "$stage/cli-root" \( -perm +022 -o -type d ! -perm 755 \) -print | head -n 1)
[ -z "$loose" ] ||
    fail "$(basename "$loose") in the app is writable by group or others, or a directory not 755 (built under another umask?)"
closed=$(find "$stage/app-root" "$stage/cli-root" -type f ! -perm -044 -print | head -n 1)
[ -z "$closed" ] || fail "$(basename "$closed") in the app is not readable by group and others"

# 2. The app component. The template lists the app and, as ChildBundles, the SwiftPM resource
# bundles inside it. Every bundle is made non-relocatable: pkgbuild on a build host before macOS 27
# defaults to true, and Installer would then update a copy of the app the user moved or kept
# elsewhere instead of installing to /Applications. No version check: a rollback must downgrade the
# app together with the CLI. `upgrade` replaces the bundle, so files a new version dropped go away
# (`update` would also skip the app on a Mac that does not have it). The strict identifier is set
# rather than left to the default of the build host.
plist=$stage/app.plist
pkgbuild --analyze --root "$stage/app-root" "$plist" >/dev/null
# Sets $1 (a PlistBuddy entry path) to $3 of type $2, whether or not the template has the key.
set_key() {
    $plistbuddy -c "Set $1 $3" "$plist" 2>/dev/null || $plistbuddy -c "Add $1 $2 $3" "$plist"
}
[ "$($plistbuddy -c 'Print :0:RootRelativeBundlePath' "$plist")" = Skillcask.app ] ||
    fail "pkgbuild --analyze did not list Skillcask.app first: $(plutil -p "$plist")"
if $plistbuddy -c 'Print :1' "$plist" >/dev/null 2>&1; then
    fail "pkgbuild --analyze found a bundle outside Skillcask.app: $(plutil -p "$plist")"
fi
set_key :0:BundleIsVersionChecked bool false
set_key :0:BundleOverwriteAction string upgrade
set_key :0:BundleHasStrictIdentifier bool true
queue=:0
while [ -n "$queue" ]; do
    # shellcheck disable=SC2086 # entry paths hold no spaces; splitting the queue is intended
    set -- $queue
    entry=$1
    shift
    queue=$*
    set_key "$entry:BundleIsRelocatable" bool false
    child=0
    while $plistbuddy -c "Print $entry:ChildBundles:$child:RootRelativeBundlePath" "$plist" >/dev/null 2>&1; do
        queue="$queue $entry:ChildBundles:$child"
        child=$((child + 1))
    done
done
if plutil -p "$plist" | grep -Eq '"BundleIs(Relocatable|VersionChecked)" => (true|1)'; then
    fail "a bundle is still relocatable or version-checked: $(plutil -p "$plist")"
fi
# The components stay unsigned: the product's signature covers them (pkgbuild(1), SIGNED PACKAGES).
pkgbuild --root "$stage/app-root" --install-location /Applications --component-plist "$plist" \
    --identifier "$pkg_id.app" --version "$version" --ownership recommended \
    "$stage/packages/Skillcask-app.pkg"

# 3. The CLI component.
pkgbuild --root "$stage/cli-root" --install-location /usr/local/bin \
    --identifier "$pkg_id.cli" --version "$version" --ownership recommended \
    "$stage/packages/skillcask-cli.pkg"

# 4. The product: one choice with both components, the system domain only, no scripts. productbuild
# adds the sizes and bundle versions to the pkg-ref elements.
cat > "$stage/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Skillcask</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="$min_os"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="Skillcask">
        <pkg-ref id="$pkg_id.app"/>
        <pkg-ref id="$pkg_id.cli"/>
    </choice>
    <pkg-ref id="$pkg_id.app" version="$version">Skillcask-app.pkg</pkg-ref>
    <pkg-ref id="$pkg_id.cli" version="$version">skillcask-cli.pkg</pkg-ref>
</installer-gui-script>
EOF
mkdir -p .build
pkg=.build/Skillcask-$version-macos-universal.pkg
rm -f "$pkg"
set -- --distribution "$stage/distribution.xml" --package-path "$stage/packages" \
    --identifier "$pkg_id" --version "$version"
signed=unsigned
if [ -n "$identity" ]; then
    set -- "$@" --sign "$identity" --timestamp
    [ -z "${INSTALLER_KEYCHAIN:-}" ] || set -- "$@" --keychain "$INSTALLER_KEYCHAIN"
    signed="signed by $identity"
fi
productbuild "$@" "$pkg"
[ -z "$identity" ] || pkgutil --check-signature "$pkg"
echo "packaged $(pwd)/$pkg ($cli_version, $signed)"
