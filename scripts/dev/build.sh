#!/bin/bash
# Debug 编译 App，只把错误和警告挑出来。完整日志在 .dev/xcodebuild.log。
set -o pipefail
cd "$(dirname "$0")/../.."
xcodegen generate --quiet || exit 1
xcodebuild -project Eyeline.xcodeproj -scheme Eyeline -configuration Debug -derivedDataPath .build \
  -destination 'platform=macOS,arch=arm64' build > .dev/xcodebuild.log 2>&1
code=$?
grep -E "error:|warning:" .dev/xcodebuild.log | grep -vE "^ld: warning|appintentsmetadataprocessor" | sort -u | head -100
tail -2 .dev/xcodebuild.log
exit $code
