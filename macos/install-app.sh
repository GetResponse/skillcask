#!/bin/sh
# Installs Skillcask.app from a skillcask release into /Applications. Attached to every release as
# skillcask-app-installer.sh:
#
#   curl --proto '=https' --tlsv1.2 -LsSf https://github.com/GetResponse/skillcask/releases/latest/download/skillcask-app-installer.sh | sh
#
# SKILLCASK_VERSION=X.Y.Z picks a release (default: the latest), SKILLCASK_APP_DIR another folder.
# An earlier copy goes to the Trash. A copy Homebrew installed is left to `brew upgrade`.
set -eu

repo=https://github.com/GetResponse/skillcask
dest=${SKILLCASK_APP_DIR:-/Applications}

fail() {
    echo "error: $*" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail "Skillcask.app is a macOS app; on this system use skillcask ui"
if command -v brew > /dev/null && [ -d "$(brew --prefix)/Caskroom/skillcask-app" ]; then
    fail "Homebrew installed Skillcask.app; update it with brew upgrade skillcask-app"
fi

version=${SKILLCASK_VERSION:-$(curl --proto '=https' --tlsv1.2 -fsSLI -o /dev/null -w '%{url_effective}' "$repo/releases/latest" | sed 's|.*/tag/v||')}
case $version in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "no release version found (got \"$version\")" ;;
esac
zip=Skillcask-$version-macos-universal.zip

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
echo "downloading $zip"
curl --proto '=https' --tlsv1.2 -fsSLO "$repo/releases/download/v$version/$zip"
curl --proto '=https' --tlsv1.2 -fsSLO "$repo/releases/download/v$version/$zip.sha256"
shasum -a 256 -c "$zip.sha256" > /dev/null || fail "$zip does not match its sha256"
ditto -x -k "$zip" .
# The checksum comes from the same release; the notarized Developer ID signature is the real check.
spctl -a Skillcask.app 2> /dev/null || fail "Gatekeeper rejects this Skillcask.app"

if [ -e "$dest/Skillcask.app" ]; then
    old="$HOME/.Trash/Skillcask $(date +%Y-%m-%d-%H%M%S).app"
    mv "$dest/Skillcask.app" "$old"
    echo "moved the earlier copy to the Trash"
fi
mv Skillcask.app "$dest/"
echo "installed Skillcask $version in $dest"
