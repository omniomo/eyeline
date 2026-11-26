#!/bin/bash
# 去掉测试写进去的录像画面设置（回到默认值）。
for key in recordPortrait recordLayout recordBackdrop bubbleX bubbleY bubbleSize; do
  defaults delete com.omniomo.eyeline $key 2>/dev/null && echo "removed $key"
done
defaults read com.omniomo.eyeline | grep -E "record|bubble"
