#!/bin/bash
# Sourced by build/test scripts. Keep generated signed bundles outside file-provider folders.
razerlite_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
razerlite_path_key="$(printf '%s' "$razerlite_root" | cksum | awk '{print $1}')"
razerlite_scratch="${RAZERLITE_BUILD_PATH:-${TMPDIR:-/tmp}/RazerLite-build-$razerlite_path_key}"
razerlite_swift_flags=(--scratch-path "$razerlite_scratch")
