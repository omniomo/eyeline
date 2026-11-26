#!/bin/bash
# 换了图标 Dock 还是旧的：让系统重新读一遍这个 App，再重启 Dock（Dock 会闪一下）。
cd "$(dirname "$0")/../.."
app="$PWD/.build/Build/Products/Debug/Eyeline.app"
touch "$app" "$app/Contents/Info.plist"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
killall Dock
sleep 2
pgrep -lx Dock
