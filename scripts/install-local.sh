#!/bin/bash
# Install a previously built, signed app. Never registers a login item.
set -euo pipefail
source "$(dirname "$0")/swift-environment.sh"
replace="${1:-}"
if [ -n "$replace" ] && [ "$replace" != --replace ]; then
    echo "Usage: $0 [--replace]" >&2; exit 2
fi
source_bundle="$HOME/Library/Caches/RazerLite/$razerlite_path_key/RazerLite.app"
destination="$HOME/Applications/RazerLite.app"
if [ ! -d "$source_bundle" ]; then
    echo "Run ./scripts/build-app.sh release first." >&2; exit 1
fi
/usr/bin/codesign --verify --strict "$source_bundle"
build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :RazerLiteBuildConfiguration' "$source_bundle/Contents/Info.plist")"
if [ "$build_configuration" != release ]; then
    echo "Build the standard Release app before installing." >&2; exit 1
fi
if [ -L "$destination" ]; then
    echo "Refusing to replace an installation symlink." >&2; exit 1
fi
if [ -e "$destination" ]; then
    if [ "$replace" != --replace ]; then
        echo "Installation exists. Quit it, then use --replace to keep a backup and update." >&2; exit 1
    fi
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
    if [ "$identifier" != local.RazerLite ]; then
        echo "Destination is not a RazerLite installation." >&2; exit 1
    fi
fi
if /bin/ps -axo command= | /usr/bin/awk -v app="$destination/Contents/MacOS/RazerLite" '$0 == app || index($0, app " ") == 1 {found=1} END {exit !found}'; then
    echo "Quit the installed RazerLite before updating." >&2; exit 1
fi
mkdir -p "$HOME/Applications"
staging="$(mktemp -d "$HOME/Applications/.RazerLite-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto --norsrc --noextattr "$source_bundle" "$staging/RazerLite.app"
/usr/bin/codesign --verify --strict "$staging/RazerLite.app"
if [ -e "$destination" ]; then
    backup_root="$HOME/Library/Application Support/RazerLite/InstallBackups"
    mkdir -p "$backup_root"
    backup="$(mktemp -d "$backup_root/previous.XXXXXX")"
    mv "$destination" "$backup/RazerLite.app"
    echo "Previous installation: $backup/RazerLite.app"
fi
mv "$staging/RazerLite.app" "$destination"
/usr/bin/codesign --verify --strict "$destination"
echo "$destination"
echo "Launch this installed copy. Enable login startup in Settings only if desired."
