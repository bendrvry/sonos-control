#!/bin/bash
# Builds dist/SonosControl.app.
#   --brightness-keys  include the brightness keys add-on (volume keys and the volume indicator)
#   install            also copy the app to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."
flags=()
install=false
for arg in "$@"; do
    case "$arg" in
        --brightness-keys) flags=(-Xswiftc -DBRIGHTNESS_KEYS) ;;
        install) install=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done
swift build -c release --product SonosControl ${flags[@]+"${flags[@]}"}
app="dist/SonosControl.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# SwiftPM records the deployment target as the SDK version, which makes AppKit fall back to the
# pre-macOS 26 look. Stamp the real SDK version so the app gets Liquid Glass controls.
vtool -set-build-version macos 26.0 "$(xcrun --show-sdk-version)" -replace \
    -output "$app/Contents/MacOS/SonosControl" "$(swift build -c release --show-bin-path ${flags[@]+"${flags[@]}"})/SonosControl"
cp Info.plist "$app/Contents/"
swift scripts/make-icon.swift "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $app"
if $install; then
    rm -rf "/Applications/SonosControl.app"
    cp -R "$app" /Applications/
    echo "Installed to /Applications"
fi
