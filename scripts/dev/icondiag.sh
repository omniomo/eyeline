#!/bin/bash
# 图标为什么没变：在跑的是哪个 Eyeline.app、它的图标文件、系统里登记了几个 Eyeline。
cd "$(dirname "$0")/../.."
for pid in $(pgrep -x Eyeline); do echo "running: $(ps -o comm= -p $pid)"; done
app=.build/Build/Products/Debug/Eyeline.app
ls -la "$app/Contents/Resources/" | grep -iE "icns|car"
/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" -c "Print :CFBundleIconFile" "$app/Contents/Info.plist"
echo "--- other copies"
mdfind "kMDItemCFBundleIdentifier == 'com.omniomo.eyeline'" 2>/dev/null
ls -d /Applications/Eyeline.app ~/Applications/Eyeline.app 2>/dev/null
echo "--- dock"
defaults read com.apple.dock persistent-apps 2>/dev/null | grep -i -A2 eyeline | head
sw_vers -productVersion
