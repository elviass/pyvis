#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
flutter=${PYVIS_FLUTTER:-flutter}
if ! command -v "$flutter" >/dev/null 2>&1; then
    flutter="$HOME/.local/share/pyvis-flutter/bin/flutter"
fi

python3 "$repo/tools/prepare_local_completion.py" --platform macos-arm64
python3 "$repo/tools/prepare_local_completion.py" --platform macos-x64

cd "$repo/client"
"$flutter" build macos --release

app="$PWD/build/macos/Build/Products/Release/Pyvis.app"
packages="$PWD/build/macos/packages"
mkdir -p "$packages"
stage=$(mktemp -d "$packages/.dmg.XXXXXX")
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then
        hdiutil detach "$stage/mount" -quiet || return
    fi
    rm -rf "$stage"
}
trap cleanup EXIT

mkdir "$stage/files" "$stage/mount"
ditto "$app" "$stage/files/Pyvis.app"
ln -s /Applications "$stage/files/Applications"
hdiutil create -quiet -volname Pyvis -srcfolder "$stage/files" -format UDZO "$stage/Pyvis.dmg"
hdiutil verify -quiet "$stage/Pyvis.dmg"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$stage/mount" "$stage/Pyvis.dmg"
mounted=true
test "$(readlink "$stage/mount/Applications")" = /Applications
codesign --verify --deep --strict "$stage/mount/Pyvis.app"
architectures=$(lipo -archs "$stage/mount/Pyvis.app/Contents/MacOS/Pyvis")
printf 'Packaged architectures: %s\n' "$architectures"
for arch in $architectures; do
    python="$stage/mount/Pyvis.app/Contents/Resources/cpython/$arch/python/bin/python3"
    test -x "$python"
    codesign --verify --strict "$python"
done
hdiutil detach -quiet "$stage/mount"
mounted=false

mv -f "$stage/Pyvis.dmg" "$packages/Pyvis.dmg"
printf '%s\n' "$packages/Pyvis.dmg"
