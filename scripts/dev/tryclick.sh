#!/bin/bash
# 试左边列表：单击能不能切过去、双击是不是改名（用 .dev/teststore 的稿子库，不碰你的）。
cd "$(dirname "$0")/../.."
pkill -x Eyeline && sleep 0.5
open -n .build/Build/Products/Debug/Eyeline.app --args -storeFolder "$PWD/.dev/teststore" -sidebarClickTest YES
sleep 9
log show --last 12s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -E "eyeline:app" | grep -i "sidebar" | cut -c60-300
pkill -x Eyeline && sleep 0.5
args=$(cat .dev/args 2>/dev/null)
open -n .build/Build/Products/Debug/Eyeline.app --args $args
