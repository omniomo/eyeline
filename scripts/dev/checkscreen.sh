#!/bin/bash
# 新开一个 Eyeline 看屏幕录制权限（只看不录，马上退出），再看看系统里记着几个 Eyeline。
cd "$(dirname "$0")/../.."
open -n .build/Build/Products/Debug/Eyeline.app --args -checkScreen YES -storeFolder "$PWD/.dev/teststore"
sleep 4
log show --last 6s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -E "screen check" | cut -c60-300
codesign -d -r- .build/Build/Products/Debug/Eyeline.app 2>&1 | tail -1 | cut -c1-120
pgrep -lx Eyeline
