#!/bin/sh
# Refresh Casks/nanolight.rb from a published release's .dmg.sha256.
# Usage: sh macos/update-cask.sh v0.2.11
#        VERSION=0.2.11 SHA256=abc... sh macos/update-cask.sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
tag=${1:-}
version=${VERSION:-}
sha=${SHA256:-}
if [ -z "$version" ]; then
  if [ -z "$tag" ]; then
    echo "usage: sh macos/update-cask.sh vX.Y.Z" >&2
    exit 1
  fi
  version=${tag#v}
fi
if [ -z "$sha" ]; then
  if [ -f zig-out/package/nanolight-macos-arm64.dmg.sha256 ]; then
    sha=$(awk '{print $1}' zig-out/package/nanolight-macos-arm64.dmg.sha256)
  else
    tmp=$(mktemp)
    url="https://github.com/justrach/nanolight/releases/download/v${version}/nanolight-macos-arm64.dmg.sha256"
    curl -fsSL "$url" -o "$tmp"
    sha=$(awk '{print $1}' "$tmp")
    rm -f "$tmp"
  fi
fi
case "$sha" in
  [0-9a-fA-F][0-9a-fA-F]*) ;;
  *) echo "bad sha256: $sha" >&2; exit 1 ;;
esac
cask=Casks/nanolight.rb
test -f "$cask"
# Rewrite version and sha256 lines only.
awk -v ver="$version" -v sha="$sha" '
  /^  version / { print "  version \"" ver "\""; next }
  /^  sha256 /  { print "  sha256 \"" sha "\""; next }
  { print }
' "$cask" > "$cask.tmp"
mv "$cask.tmp" "$cask"
echo "Casks/nanolight.rb -> $version $sha"
