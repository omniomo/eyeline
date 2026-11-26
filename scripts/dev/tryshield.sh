#!/bin/bash
# 回放一条再换一条：回放上面的光标还是箭头吗（单独的稿子库和录像文件夹，自己退出）。
cd "$(dirname "$0")/../.."
open -n .build/Build/Products/Debug/Eyeline.app --args -storeFolder "$PWD/.dev/teststore" -takesFolder "$PWD/.dev/testtakes" -showTake switch
sleep 6
log show --last 8s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -E "shield test" | cut -c60-260
