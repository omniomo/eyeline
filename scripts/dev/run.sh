#!/bin/bash
# 重新打开刚编译好的 App。.dev/args 里可以写启动参数，比如 -autostart steady。
cd "$(dirname "$0")/../.."
pkill -x Eyeline && sleep 0.5
args=$(cat .dev/args 2>/dev/null)
open -n .build/Build/Products/Debug/Eyeline.app --args $args
sleep 2
pgrep -x Eyeline && echo running
