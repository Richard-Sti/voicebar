#!/bin/bash
# Compiles and runs Tests/main.swift against the app's non-GUI sources.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14" \
    Sources/Config.swift Sources/Hotkeys.swift Sources/Audio.swift Sources/API.swift Sources/Indicator.swift \
    Tests/main.swift -o build/check
build/check "$@"
