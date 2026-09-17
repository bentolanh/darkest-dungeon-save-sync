#!/bin/bash
# Builds build/Stagecoach.dmg: the app, and an Applications folder to drag it to.
set -euo pipefail
cd "$(dirname "$0")"

[ -d build/Stagecoach.app ] || { echo "build/Stagecoach.app not found — run ./build.sh first"; exit 1; }

VOL="Stagecoach"
STAGE="$(mktemp -d)/$VOL"
mkdir -p "$STAGE"
cp -R build/Stagecoach.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f build/Stagecoach.dmg
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO -quiet build/Stagecoach.dmg
rm -rf "$(dirname "$STAGE")"

echo "Built build/Stagecoach.dmg ($(du -h build/Stagecoach.dmg | cut -f1))"
