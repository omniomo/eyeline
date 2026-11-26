#!/bin/bash
# 左边列表画成图看看（单独的稿子库，录像用你「影片/Eyeline」里的，只读）。
cd "$(dirname "$0")/../.."
rm -f .dev/list.png 2>/dev/null
open -n .build/Build/Products/Debug/Eyeline.app --args -storeFolder "$PWD/.dev/teststore" -windowShot "$PWD/.dev/list.png"
sleep 5
ls -la .dev/list.png
pid=$(pgrep -n -x Eyeline); [ -n "$pid" ] && kill $pid
