#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

xcodegen generate --quiet
rm -rf "$ROOT_DIR/DerivedData"

xcodebuild \
  -project CareThread.xcodeproj \
  -scheme CareThread \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -derivedDataPath "$ROOT_DIR/DerivedData" \
  -resultBundlePath "$ROOT_DIR/DerivedData/Verify.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  build test

