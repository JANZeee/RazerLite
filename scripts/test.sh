#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/swift-environment.sh"
cd "$razerlite_root"
razerlite_developer_dir="$(xcode-select -p)"
razerlite_testing_plugin="$razerlite_developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
razerlite_test_flags=(--disable-xctest)
# This CLT Swift build engine does not resolve its bundled Testing plugin automatically.
if [ -f "$razerlite_testing_plugin" ]; then
    razerlite_test_flags+=(-Xswiftc -load-plugin-library -Xswiftc "$razerlite_testing_plugin")
fi
swift test "${razerlite_swift_flags[@]}" "${razerlite_test_flags[@]}"
