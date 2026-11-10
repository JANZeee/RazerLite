#!/bin/bash
# Install a previously built, signed app. Never registers a login item.

verify_razerlite_release() {
    /usr/bin/codesign --verify --strict "$1" || return
    local identifier configuration
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" || return
    configuration="$(/usr/libexec/PlistBuddy -c 'Print :RazerLiteBuildConfiguration' "$1/Contents/Info.plist")" || return
    if [ "$identifier" != local.RazerLite ] || [ "$configuration" != release ]; then
        echo "Build the standard RazerLite Release app before installing." >&2
        return 1
    fi
}

# Explicit paths keep the transaction testable in temporary directories. The
# ordinary CLI below always uses the stable user Applications destination.
install_razerlite_release() (
    set -euo pipefail
    source_bundle="$1"
    destination="$2"
    backup_root="$3"
    replace="${4:-}"
    staging=""
    lock=""
    backup=""
    promotion_requested=false
    new_identity=""
    committed=false

    cleanup() {
        result=$?
        trap - EXIT INT TERM
        set +e
        if [ "$committed" = false ]; then
            # A signal can arrive after mv succeeds but before the next shell
            # assignment. Use pre-recorded intent and filesystem identity, not
            # a post-move flag. Never remove somebody else's replacement path.
            new_installed=false
            if [ "$promotion_requested" = true ] && [ ! -L "$destination" ] && \
                [ "$(/usr/bin/stat -f '%d:%i' "$destination" 2>/dev/null)" = "$new_identity" ]; then
                new_installed=true
                if ! rm -rf "$destination"; then
                    echo "Could not remove the unverified installation: $destination" >&2
                fi
            fi
            if [ -n "$backup" ] && [ -d "$backup/RazerLite.app" ] && [ ! -L "$backup/RazerLite.app" ]; then
                if [ ! -e "$destination" ] && [ ! -L "$destination" ] && mv "$backup/RazerLite.app" "$destination"; then
                    echo "Update failed; previous installation restored: $destination" >&2
                else
                    echo "Update failed. Previous installation is preserved at: $backup/RazerLite.app" >&2
                    echo "Move that app back to $destination after resolving the installation error." >&2
                fi
            elif [ "$new_installed" = true ] && [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
                echo "Installation failed; the unverified new app was removed." >&2
            fi
        fi
        if [ -n "$staging" ]; then rm -rf "$staging"; fi
        if [ -n "$backup" ]; then rmdir "$backup" 2>/dev/null; fi
        if [ -n "$lock" ]; then rmdir "$lock"; fi
        exit "$result"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [ ! -d "$source_bundle" ]; then
        echo "Run ./scripts/build-app.sh release first." >&2; exit 1
    fi
    verify_razerlite_release "$source_bundle"
    parent="$(dirname "$destination")"
    mkdir -p "$parent"
    lock_candidate="$parent/.RazerLite-install.lock"
    if ! mkdir "$lock_candidate" 2>/dev/null; then
        echo "Another installation is active, or an interrupted installer left a lock: $lock_candidate" >&2
        echo "Do not remove this lock while another installer is running." >&2; exit 1
    fi
    lock="$lock_candidate"
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
    staging="$(mktemp -d "$parent/.RazerLite-install.XXXXXX")"
    /usr/bin/ditto --norsrc --noextattr "$source_bundle" "$staging/RazerLite.app"
    verify_razerlite_release "$staging/RazerLite.app"
    new_identity="$(/usr/bin/stat -f '%d:%i' "$staging/RazerLite.app")"
    if [ -e "$destination" ]; then
        mkdir -p "$backup_root"
        backup="$(mktemp -d "$backup_root/previous.XXXXXX")"
        mv "$destination" "$backup/RazerLite.app"
    fi
    # Do not nest the new app in a destination created during installation.
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        echo "Installation destination changed; update stopped." >&2; exit 1
    fi
    promotion_requested=true
    mv "$staging/RazerLite.app" "$destination"
    verify_razerlite_release "$destination"
    committed=true
    if [ -n "$backup" ]; then echo "Previous installation: $backup/RazerLite.app"; fi
    echo "$destination"
    echo "Launch this installed copy. Enable login startup in Settings only if desired."
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    if [ "$#" -gt 1 ] || { [ -n "${1:-}" ] && [ "$1" != --replace ]; }; then
        echo "Usage: $0 [--replace]" >&2; exit 2
    fi
    source "$(dirname "$0")/swift-environment.sh"
    install_razerlite_release "$HOME/Library/Caches/RazerLite/$razerlite_path_key/RazerLite.app" \
        "$HOME/Applications/RazerLite.app" "$HOME/Library/Application Support/RazerLite/InstallBackups" "${1:-}"
fi
