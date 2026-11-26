#!/bin/bash
# 试关键词模式：不录像、自动开始，6 秒后截菜单栏、看日志，然后按原样重新打开。
cd "$(dirname "$0")/../.."
before=$(defaults read com.omniomo.eyeline mode 2>/dev/null)
pkill -x Eyeline && sleep 0.5
rm -f .dev/ribbon*.png; open -n .build/Build/Products/Debug/Eyeline.app --args -hideFromCapture NO -autostart keywords -recordTakes NO -autostartIndex 1 -ribbonShot "$PWD/.dev/ribbon.png"
sleep 8

echo "mode now: $(defaults read com.omniomo.eyeline mode)"
log show --last 20s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -iE "eyeline:app|ribbon|error|fault" | cut -c1-200 | tail -15
pgrep -lx Eyeline || echo "not running"
defaults write com.omniomo.eyeline mode -string "${before:-steady}"
pkill -x Eyeline && sleep 0.5
args=$(cat .dev/args 2>/dev/null)
open -n .build/Build/Products/Debug/Eyeline.app --args $args
echo "restored mode: $(defaults read com.omniomo.eyeline mode)"
