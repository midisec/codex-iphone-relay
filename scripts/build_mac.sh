#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/manual
FLAGS=(-swift-version 5 -target "$(uname -m)-apple-macosx13.0")
# Some upgraded CLT installations contain two declarations of SwiftBridging.
# Hide only the duplicate module map through a compiler overlay, never edit the SDK.
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ -f "$DEV_DIR/usr/include/swift/bridging.modulemap" && -f "$DEV_DIR/usr/include/swift/module.modulemap" ]]; then
  /usr/bin/python3 - "$DEV_DIR" "$PWD/.build/manual" <<'PY'
import json, pathlib, sys
dev, build = map(pathlib.Path, sys.argv[1:])
empty = build / 'empty.modulemap'
empty.write_text('// Duplicate module declaration hidden for this build only.\n')
overlay = {'version': 0, 'roots': [{'type': 'file', 'name': str(dev / 'usr/include/swift/module.modulemap'), 'external-contents': str(empty)}]}
(build / 'swift-overlay.json').write_text(json.dumps(overlay))
PY
  FLAGS+=(-vfsoverlay "$PWD/.build/manual/swift-overlay.json")
fi
swiftc "${FLAGS[@]}" -O -enable-testing -emit-library -emit-module -module-name BridgeCore \
  Sources/BridgeCore/*.swift -o .build/manual/libBridgeCore.dylib \
  -emit-module-path .build/manual/BridgeCore.swiftmodule -Xlinker -install_name -Xlinker @rpath/libBridgeCore.dylib
for PRODUCT in BridgeMac BridgeRelay; do
  if [[ "$PRODUCT" == BridgeMac ]]; then OUTPUT=BluetoothCodex; else OUTPUT=RelayHarness; fi
  swiftc "${FLAGS[@]}" -O -I .build/manual -L .build/manual -lBridgeCore \
    -Xlinker -rpath -Xlinker @executable_path Sources/"$PRODUCT"/main.swift -o .build/manual/"$OUTPUT"
done
echo 'Mac binaries built in .build/manual'
