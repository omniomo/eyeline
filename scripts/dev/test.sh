#!/bin/bash
# 跑跟读算法的测试（不用编译整个 App）。
set -o pipefail
cd "$(dirname "$0")/../.."
xcodegen generate --quiet || exit 1
xcodebuild -project Eyeline.xcodeproj -scheme EyelineCore -destination 'platform=macOS' \
  -derivedDataPath .build test > .dev/xcodebuild-test.log 2>&1
code=$?
grep -E "error:|failed|passed|Executed|XCTAssert|\*\* TEST" .dev/xcodebuild-test.log | sort -u | head -120
exit $code
