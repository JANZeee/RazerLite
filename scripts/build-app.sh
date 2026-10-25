#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-environment.sh"
cd "$razerlite_root"
configuration="${1:-release}"
variant="${2:-standard}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
case "$variant" in standard|scenarios) ;; *) echo "Unknown app variant" >&2; exit 2 ;; esac
if [ "$variant" = scenarios ] && [ "$configuration" != debug ]; then
    echo "Offline scenarios require Debug" >&2; exit 2
fi
if [ ! -f Resources/AppIcon.icns ] || [ scripts/render-app-icon.swift -nt Resources/AppIcon.icns ]; then
    xcrun swift scripts/render-app-icon.swift "$razerlite_scratch/Icon" "$razerlite_root/Resources/AppIcon.icns"
fi
swift build "${razerlite_swift_flags[@]}" -c "$configuration"
binary_dir="$(swift build "${razerlite_swift_flags[@]}" -c "$configuration" --show-bin-path)"
app_name=RazerLite
if [ "$variant" = scenarios ]; then app_name=RazerLite-Scenarios; fi
bundle="$HOME/Library/Caches/RazerLite/$razerlite_path_key/$app_name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/RazerLite" "$bundle/Contents/MacOS/RazerLite"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RazerLiteBuildConfiguration string $configuration" "$bundle/Contents/Info.plist"
if [ "$variant" = scenarios ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.RazerLite.Scenarios' "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName RazerLite Scenarios' "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :RazerLiteOfflineScenarios bool true' "$bundle/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$bundle/Contents/PkgInfo"
# Only clear extended attributes on our generated app, never source/user directories.
/usr/bin/xattr -cr "$bundle"
/usr/bin/codesign --force --sign - --options runtime "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
mkdir -p "$razerlite_root/build"
# FileProvider immediately reattaches FinderInfo even after copying a signed .app.
# A workspace link keeps the actual signed bundle on a normal local cache volume.
destination="$razerlite_root/build/$app_name.app"
rm -rf "$destination"
ln -s "$bundle" "$destination"
/usr/bin/codesign --verify --strict "$destination"
cp "$binary_dir/razerlite-probe" "$razerlite_root/build/razerlite-probe"
echo "$destination"
