#!/bin/sh
# Checks the installer package `pkg.sh` wrote: ./Scripts/check-pkg.sh <pkg> [--install]
#
# Without --install it only reads the package (no root, signed or unsigned): what administrators
# rely on must hold before anything is installed.
# 1. Payload: the app component holds Skillcask.app and nothing else, the CLI component the single
#    file `skillcask`; each is rooted at its install location (/Applications, /usr/local/bin), so
#    no entry names /usr or /usr/local. Each payload and its bill of materials agree.
# 2. No scripts, no relocatable bundle or component (Installer would update a moved copy of the app
#    instead of installing to /Applications), no version-checked bundle (a rollback must be
#    possible). The app replaces an existing bundle (`upgrade`: `update` would merge into it, and
#    skip a Mac without the app) and only one with its own identifier. No restart or logout.
# 3. Identifiers and versions: the product, both components and the app agree on one version.
# 4. Distribution: both architectures, the system domain only, a minimum macOS; no script, no
#    choice that can be switched off, no component that is inactive or asks for a restart.
# 5. Ownership root:wheel for every entry, directories 755, files 644 or 755 (so nothing unreadable,
#    group- or world-writable, setuid), no symbolic link (the app has none), the CLI 755.
# 6. The payload, extracted as Installer would write it: no extended attribute but
#    com.apple.provenance (no quarantine flag), the app and the CLI verify, the CLI is the app's
#    helper byte for byte, the minimum macOS is the app's.
#
# With --install (only on a throwaway runner, such as CI's macos-pkg job or the release job, never on
# a personal Mac: it uses sudo and installs into / of the machine it runs on) it then installs the
# package and checks that /Applications, /usr/local and /usr/local/bin keep their owner, group, mode
# and flags (a directory that was absent is created root:wheel 755), that the CLI in /usr/local/bin
# is the app's helper byte for byte and names the package version, that both receipts exist and
# that the installed code verifies. CHECK_PKG_ABSENT=<path>, with --install only, names a path that
# must not exist after the install, such as a file put into an existing Skillcask.app beforehand:
# the app must be replaced, not merged into (checked before codesign, which would also fail).
#
# pkgbuild archives the extended attributes of a file as an AppleDouble entry `._<name>` next to
# it, and Installer applies it to the file. Such entries are counted and reported, not refused:
# where the system tags the files a build writes with com.apple.provenance (seen on a developer's
# Mac with macOS 27; a CI runner may write none) nearly every file has one. What they hold is
# checked in step 6. After an install none may be left on disk as a file.
set -eu

fail() {
    echo "check-pkg.sh: $*" >&2
    exit 1
}
ok() { echo "ok: $*"; }

pkg=${1:-}
install=0
case "${2:-}" in
"") ;;
--install) install=1 ;;
*) fail "usage: check-pkg.sh <pkg> [--install]" ;;
esac
[ -f "$pkg" ] || fail "usage: check-pkg.sh <pkg> [--install]"
absent=${CHECK_PKG_ABSENT:-}
[ -z "$absent" ] || [ "$install" = 1 ] || fail "CHECK_PKG_ABSENT is checked only with --install"

# The package identifiers (the organisation's reverse-domain namespace, com.getresponse) and the
# app's bundle identifier are independent.
pkg_id=com.getresponse.skillcask.pkg
bundle_id=io.github.puniserv.skillcask

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
x=$tmp/expanded
pkgutil --expand "$pkg" "$x"

# Prints the XPath expression $2 evaluated on the XML file $1.
xp() { xmllint --xpath "$2" "$1"; }

# The components, by identifier (their file names are not part of the contract).
app_dir=
cli_dir=
for dir in "$x"/*.pkg; do
    [ -f "$dir/PackageInfo" ] || fail "$(basename "$dir") has no PackageInfo"
    case "$(xp "$dir/PackageInfo" 'string(/pkg-info/@identifier)')" in
    "$pkg_id.app") app_dir=$dir ;;
    "$pkg_id.cli") cli_dir=$dir ;;
    *) fail "unexpected component $(basename "$dir"): $(xp "$dir/PackageInfo" 'string(/pkg-info/@identifier)')" ;;
    esac
done
[ -n "$app_dir" ] || fail "no component $pkg_id.app"
[ -n "$cli_dir" ] || fail "no component $pkg_id.cli"
[ -f "$x/Distribution" ] || fail "no Distribution: not a product archive"

# --- 1. Payload -------------------------------------------------------------------------------------
# Path, mode, uid, gid of every entry, tab-separated.
lsbom -p fmug "$app_dir/Bom" > "$tmp/app.bom"
lsbom -p fmug "$cli_dir/Bom" > "$tmp/cli.bom"
# The paths in bill of materials $1 without the AppleDouble entries of files that are in it too.
files() {
    awk -F'\t' '
        { path[NR] = $1; seen[$1] = 1 }
        END {
            for (i = 1; i <= NR; i++) {
                n = split(path[i], part, "/")
                base = part[n]
                if (substr(base, 1, 2) == "._" &&
                    (substr(path[i], 1, length(path[i]) - length(base)) substr(base, 3)) in seen) continue
                print path[i]
            }
        }' "$1"
}
files "$tmp/app.bom" > "$tmp/app.files"
files "$tmp/cli.bom" > "$tmp/cli.files"
outside=$(grep -vE '^\.$|^\./Skillcask\.app(/|$)' "$tmp/app.files" | head -n 3 || true)
[ -z "$outside" ] || fail "the app component holds more than Skillcask.app: $(echo $outside)"
for path in ./Skillcask.app/Contents/Info.plist ./Skillcask.app/Contents/MacOS/Skillcask \
    ./Skillcask.app/Contents/Helpers/skillcask; do
    grep -qxF "$path" "$tmp/app.files" || fail "the app component lacks $path"
done
[ "$(tr '\n' ' ' < "$tmp/cli.files")" = ". ./skillcask " ] ||
    fail "the CLI component is not the single file skillcask: $(tr '\n' ' ' < "$tmp/cli.files")"
# The bill of materials is what was read above; the archive is what gets installed. On a product
# `pkgutil --payload-files` lists the first component only, so each one is flattened and listed.
same_payload() {
    pkgutil --flatten "$2" "$tmp/$1.pkg"
    pkgutil --payload-files "$tmp/$1.pkg" | sort > "$tmp/$1.payload"
    cut -f 1 "$tmp/$1.bom" | sort | cmp -s - "$tmp/$1.payload" ||
        fail "the payload of the $1 component and its bill of materials list different files"
}
same_payload app "$app_dir"
same_payload cli "$cli_dir"
double=$(($(cat "$tmp/app.bom" "$tmp/cli.bom" | wc -l) - $(cat "$tmp/app.files" "$tmp/cli.files" | wc -l)))
ok "payload: Skillcask.app ($(($(wc -l < "$tmp/app.files") - 1)) entries) and skillcask, $double AppleDouble entries"

# --- 2. No scripts, no relocation, no version check ---------------------------------------------------
for dir in "$app_dir" "$cli_dir"; do
    name=$(basename "$dir")
    [ ! -e "$dir/Scripts" ] || fail "$name has a Scripts directory"
    [ "$(xp "$dir/PackageInfo" 'count(/pkg-info/scripts)')" = 0 ] || fail "$name declares scripts"
    # pkgbuild lists a relocatable bundle in <relocate> and a version-checked one in <bundle-version>;
    # both elements are there, empty, when no bundle is.
    [ "$(xp "$dir/PackageInfo" 'count(/pkg-info/relocate/*)')" = 0 ] || fail "$name has a relocatable bundle"
    [ "$(xp "$dir/PackageInfo" 'count(/pkg-info/bundle-version/*)')" = 0 ] ||
        fail "$name has a version-checked bundle"
    [ "$(xp "$dir/PackageInfo" 'string(/pkg-info/@auth)')" = root ] || fail "$name does not install as root"
    # The component itself: pkgbuild writes relocatable="false" and postinstall-action="none".
    case "$(xp "$dir/PackageInfo" 'string(/pkg-info/@relocatable)')" in
    "" | false) ;;
    *) fail "$name is relocatable" ;;
    esac
    action=$(xp "$dir/PackageInfo" 'string(/pkg-info/@postinstall-action)')
    case "$action" in
    "" | none) ;;
    *) fail "$name asks for '$action' after the install" ;;
    esac
    # BundleOverwriteAction=update lists the bundle in <update-bundle>; pkgbuild writes
    # <atomic-update-bundle> too, always empty.
    [ "$(xp "$dir/PackageInfo" 'count(/pkg-info/update-bundle/*) + count(/pkg-info/atomic-update-bundle/*)')" = 0 ] ||
        fail "$name has a bundle that is updated in place: it is not replaced, and not installed on a Mac without it"
done
[ ! -e "$x/Scripts" ] && [ ! -e "$x/Resources" ] || fail "the product has scripts or resources"
[ "$(xp "$app_dir/PackageInfo" "count(/pkg-info/upgrade-bundle/bundle[@id='$bundle_id'])")" = 1 ] ||
    fail "the app component does not replace an existing Skillcask.app (no upgrade-bundle $bundle_id)"
[ "$(xp "$app_dir/PackageInfo" "count(/pkg-info/strict-identifier/bundle[@id='$bundle_id'])")" = 1 ] ||
    fail "the app component would replace a bundle with another identifier (no strict-identifier $bundle_id)"
ok "no scripts, nothing relocatable or version-checked, Skillcask.app is replaced (upgrade, strict identifier)"

# --- 3. Install locations, identifiers, versions ------------------------------------------------------
[ "$(xp "$app_dir/PackageInfo" 'string(/pkg-info/@install-location)')" = /Applications ] ||
    fail "the app component does not install to /Applications"
[ "$(xp "$cli_dir/PackageInfo" 'string(/pkg-info/@install-location)')" = /usr/local/bin ] ||
    fail "the CLI component does not install to /usr/local/bin"
[ "$(xp "$x/Distribution" 'string(/installer-gui-script/product/@id)')" = "$pkg_id" ] ||
    fail "the product identifier is not $pkg_id"
version=$(xp "$x/Distribution" 'string(/installer-gui-script/product/@version)')
[ -n "$version" ] || fail "the product has no version"
same_version() {
    [ "$2" = "$version" ] || fail "$1 has the version '$2', the product $version"
}
same_version "the app component" "$(xp "$app_dir/PackageInfo" 'string(/pkg-info/@version)')"
same_version "the CLI component" "$(xp "$cli_dir/PackageInfo" 'string(/pkg-info/@version)')"
same_version "the app" "$(xp "$app_dir/PackageInfo" \
    "string(/pkg-info/bundle[@id='$bundle_id'][@path='./Skillcask.app']/@CFBundleShortVersionString)")"
for id in "$pkg_id.app" "$pkg_id.cli"; do
    same_version "the Distribution's $id" \
        "$(xp "$x/Distribution" "string(/installer-gui-script/pkg-ref[@id='$id'][@version]/@version)")"
    [ "$(xp "$x/Distribution" "count(/installer-gui-script/choice/pkg-ref[@id='$id'])")" = 1 ] ||
        fail "no choice installs $id"
done
ok "identifiers $pkg_id, .app (/Applications) and .cli (/usr/local/bin), all at version $version"

# --- 4. Distribution ----------------------------------------------------------------------------------
[ "$(xp "$x/Distribution" 'string(/installer-gui-script/options/@hostArchitectures)')" = arm64,x86_64 ] ||
    fail "the Distribution does not declare hostArchitectures=\"arm64,x86_64\""
domains=$(xp "$x/Distribution" 'concat(/installer-gui-script/domains/@enable_localSystem, " ",
    /installer-gui-script/domains/@enable_currentUserHome, " ", /installer-gui-script/domains/@enable_anywhere)')
[ "$domains" = "true false false" ] ||
    fail "the Distribution does not allow the system domain only (localSystem currentUserHome anywhere: $domains)"
min_os=$(xp "$x/Distribution" 'string(/installer-gui-script/volume-check/allowed-os-versions/os-version/@min)')
printf '%s\n' "$min_os" | grep -Eqx '[0-9]+(\.[0-9]+)*' || fail "the Distribution names no minimum macOS ('$min_os')"
# Nothing that runs or decides at install time: with customize="never" a choice attribute could
# still deselect or hide a component, and a pkg-ref switch it off or ask for a restart.
[ "$(xp "$x/Distribution" 'count(//script) + count(//@script)')" = 0 ] || fail "the Distribution carries a script"
[ "$(xp "$x/Distribution" 'count(//choice/@start_selected | //choice/@start_enabled | //choice/@start_visible |
    //choice/@selected | //choice/@enabled | //choice/@visible)')" = 0 ] ||
    fail "a choice in the Distribution sets whether it is selected, enabled or visible"
[ "$(xp "$x/Distribution" "count(//pkg-ref[@active and @active != 'true'])")" = 0 ] ||
    fail "a pkg-ref in the Distribution is not active"
[ "$(xp "$x/Distribution" "count(//pkg-ref[@onConclusion and @onConclusion != 'none'])")" = 0 ] ||
    fail "a pkg-ref in the Distribution asks for '$(xp "$x/Distribution" 'string(//pkg-ref/@onConclusion)')' after the install"
[ "$(xp "$x/Distribution" "count(//pkg-ref[@auth and @auth != 'root'])")" = 0 ] ||
    fail "a pkg-ref in the Distribution does not install as root"
ok "distribution: arm64 and x86_64, system domain only, macOS $min_os or newer, no script, nothing optional"

# --- 5. Ownership and modes ---------------------------------------------------------------------------
# An AppleDouble entry has the mode of its file and sorts before it: the file is the one to name.
bad=$(cat "$tmp/app.bom" "$tmp/cli.bom" | awk -F'\t' '
    function report(text) {
        if (first == "") first = text
        if (file == "" && $1 !~ /(^|\/)\._[^\/]*$/) file = text
    }
    $3 != 0 || $4 != 0 { report($1 " is owned by " $3 "/" $4); next }
    length($2) == 6 && substr($2, 1, 2) == "12" { report($1 " is a symbolic link (the app has none)"); next }
    $2 != "40755" && $2 != "100644" && $2 != "100755" {
        report($1 " has the mode " $2 ", not 40755 (directory), 100644 or 100755 (file)") }
    END { print (file != "" ? file : first) }')
[ -z "$bad" ] || fail "$bad"
cli_mode=$(awk -F'\t' '$1 == "./skillcask" { print $2 }' "$tmp/cli.bom")
[ "$cli_mode" = 100755 ] || fail "skillcask has the mode $cli_mode, not 100755"
ok "ownership 0/0 everywhere, directories 755, files 644 or 755, no symbolic link, skillcask 755"

# --- 6. The payload, extracted ------------------------------------------------------------------------
# As Installer would write it, AppleDouble entries applied to their files, but owned by this user.
full=$tmp/full
pkgutil --expand-full "$pkg" "$full"
app=$full/$(basename "$app_dir")/Payload/Skillcask.app
cli=$full/$(basename "$cli_dir")/Payload/skillcask
[ -f "$app/Contents/Info.plist" ] && [ -f "$cli" ] || fail "pkgutil --expand-full did not extract the app and the CLI"
# com.apple.provenance is all a payload may carry: the system sets it on files a build writes (and
# on these extracted ones) and does not let it be removed. Anything else was packaged, above all
# com.apple.quarantine, which would be installed with the app. PackageKit's own
# com.apple.PackageKit.PayloadEncoding is on the component directory, outside Payload.
left=$(xattr -r "$(dirname "$app")" "$(dirname "$cli")" | grep -v ': com\.apple\.provenance$' | head -n 3 || true)
[ -z "$left" ] ||
    fail "the payload carries an extended attribute: $(printf '%s\n' "$left" | sed "s|^$full/||" | tr '\n' ' ')"
app_min_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist") ||
    fail "the app in the payload has no LSMinimumSystemVersion"
[ "$min_os" = "$app_min_os" ] ||
    fail "the Distribution allows macOS $min_os or newer, the app needs $app_min_os"
# --strict also refuses a file the signature does not cover.
codesign --verify --strict "$app" || fail "the app in the payload does not pass codesign --verify --strict"
codesign --verify --strict "$cli" || fail "the CLI in the payload does not pass codesign --verify --strict"
cmp -s "$cli" "$app/Contents/Helpers/skillcask" || fail "the CLI in the payload is not the app's helper"
ok "extracted payload: no extended attribute but com.apple.provenance, the app and the CLI verify, the CLI is the app's helper"

[ "$install" = 1 ] || exit 0

# --- 7. Install (throwaway runner only) ---------------------------------------------------------------
dirs="/Applications /usr/local /usr/local/bin"
# Owner, group, mode with the setuid, setgid and sticky bits, and file flags of $1, or `absent`.
state() {
    if [ -e "$1" ]; then stat -f '%Su:%Sg %Mp%Lp %Sf' "$1"; else echo absent; fi
}
for dir in $dirs; do
    echo "$dir	$(state "$dir")"
done > "$tmp/before"
# -allowUntrusted only for a package nobody signed (a CI build). A signed one gets no such help: it
# installs only when Installer trusts its certificate chain, which is part of what is checked.
if pkgutil --check-signature "$pkg" | grep -q 'Status: no signature'; then
    sudo installer -pkg "$pkg" -target / -allowUntrusted
else
    sudo installer -pkg "$pkg" -target /
fi
# The payload's entry for an install location is root:wheel 755: it may create the directory, not
# change one that is there. The whole table is printed before a difference fails the check.
changed=
while IFS='	' read -r dir before; do
    after=$(state "$dir")
    echo "$dir: before the install '$before', after it '$after'"
    if [ "$before" = absent ]; then
        [ "$after" = "root:wheel 0755 -" ] || changed="$changed; created $dir as '$after', not 'root:wheel 0755 -'"
    else
        [ "$after" = "$before" ] || changed="$changed; changed $dir from '$before' to '$after'"
    fi
done < "$tmp/before"
[ -z "$changed" ] || fail "the install ${changed#; }"
ok "install: /Applications, /usr/local and /usr/local/bin keep owner, group, mode and flags"

# A path that existed only in the bundle the install replaced (CHECK_PKG_ABSENT) must be gone.
if [ -n "$absent" ] && { [ -e "$absent" ] || [ -L "$absent" ]; }; then
    fail "$absent is still there: the install merged into the existing Skillcask.app instead of replacing it"
fi
[ -z "$absent" ] || ok "replaced: $absent is gone"

app=/Applications/Skillcask.app
cli=/usr/local/bin/skillcask
cli_version=$("$cli" --version) || fail "$cli --version failed"
case "$cli_version" in
"skillcask $version" | "skillcask $version "*) ;;
*) fail "$cli is '$cli_version', the package $version" ;;
esac
cmp "$cli" "$app/Contents/Helpers/skillcask" || fail "$cli is not the app's helper"
[ "$(state "$cli")" = "root:wheel 0755 -" ] || fail "$cli is '$(state "$cli")', not 'root:wheel 0755 -'"
[ ! -e /usr/local/bin/._skillcask ] && [ ! -e /Applications/._Skillcask.app ] ||
    fail "the install left an AppleDouble file on disk"
app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$app_version" = "$version" ] || fail "$app is $app_version, the package $version"
ok "installed: $cli ($cli_version) is the helper of $app $app_version"

for id in "$pkg_id.app" "$pkg_id.cli"; do
    pkgutil --pkg-info "$id" > "$tmp/receipt" || fail "no receipt for $id"
    grep -qx "version: $version" "$tmp/receipt" ||
        fail "the receipt of $id is not at $version: $(tr '\n' ' ' < "$tmp/receipt")"
done
ok "receipts: $pkg_id.app and $pkg_id.cli at $version"

# --strict also refuses a file the signature does not cover, such as an AppleDouble left in the app.
codesign --verify --strict "$app" || fail "$app does not pass codesign --verify --strict"
codesign --verify --strict "$cli" || fail "$cli does not pass codesign --verify --strict"
ok "codesign: the installed app and CLI verify"
