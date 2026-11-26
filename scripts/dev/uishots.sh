#!/bin/bash
# 几块界面单独画出来看（用单独的稿子库），画完自己退出。
cd "$(dirname "$0")/../.."
rm -f .dev/ui-*.png 2>/dev/null
open -n .build/Build/Products/Debug/Eyeline.app --args -storeFolder "$PWD/.dev/teststore" -uiShots "$PWD/.dev/ui.png"
sleep 5
ls -la .dev/ui-*.png
log show --last 7s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -E "ui shots" | cut -c60-200
