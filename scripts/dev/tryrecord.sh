#!/bin/bash
# 试录像：单独的稿子库和录像文件夹（不碰你的稿子和录过的），假镜头、不录声音（不开摄像头和麦克风）。
# 每种画面录 5 秒，看日志、放映窗口截图、录像里抽的帧，然后按原样重新打开。
cd "$(dirname "$0")/../.."
pdf="$PWD/.dev/deck-test.pdf"
rm -rf .dev/teststore .dev/testtakes && mkdir -p .dev/teststore .dev/testtakes
pkill -x Eyeline && sleep 0.5
rm -f .dev/rec*.png
open -n .build/Build/Products/Debug/Eyeline.app --args -storeFolder "$PWD/.dev/teststore" -takesFolder "$PWD/.dev/testtakes" \
  -hideFromCapture NO -fakeCamera YES -fakeScreen YES -noAudio YES -recordTest "$pdf" -deckShot "$PWD/.dev/rec.png"
sleep 40
log show --last 46s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -E "eyeline:app" | grep -iE "record|composite|slides:|bubble|screen:" | cut -c60-460
log show --last 46s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -iE " E | fault" | cut -c1-200 | tail -5
pgrep -lx Eyeline || echo "not running"
ls -la .dev/rec*.png .dev/testtakes
pkill -x Eyeline && sleep 0.5
args=$(cat .dev/args 2>/dev/null)
open -n .build/Build/Products/Debug/Eyeline.app --args $args
