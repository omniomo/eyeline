#!/bin/bash
# 试回放：静音打开最新的一条，3 秒后把主窗口画成 .dev/window.png，然后按原样重新打开。
cd "$(dirname "$0")/../.."
pkill -x Eyeline && sleep 0.5
rm -f .dev/window.png
open -n .build/Build/Products/Debug/Eyeline.app --args -hideFromCapture NO -showTake latest -muteTakes YES -windowShot "$PWD/.dev/window.png"
sleep 5
pgrep -lx Eyeline || echo "not running"
ls -la .dev/window.png
pkill -x Eyeline && sleep 0.5
args=$(cat .dev/args 2>/dev/null)
open -n .build/Build/Products/Debug/Eyeline.app --args $args
