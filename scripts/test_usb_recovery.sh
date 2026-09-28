#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FLAGS=(-swift-version 5 -target "$(uname -m)-apple-macosx13.0")
if [[ -f .build/manual/swift-overlay.json ]]; then FLAGS+=(-vfsoverlay "$PWD/.build/manual/swift-overlay.json"); fi
swiftc "${FLAGS[@]}" -I .build/manual -L .build/manual -lBridgeCore -Xlinker -rpath -Xlinker @executable_path Tests/USBRecoveryChecks.swift -o .build/manual/USBRecoveryChecks
.build/manual/USBRecoveryChecks
