#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
SDK="$(xcrun --show-sdk-path)"
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macos15.0" \
  Sources/Stagecoach/{Paths,Snapshot,Ledger,SyncEngine,SteamCloud,Processes,Watcher}.swift \
  Tests/main.swift -o build/engine_test
build/engine_test
