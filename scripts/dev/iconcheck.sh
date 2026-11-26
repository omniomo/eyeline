#!/bin/bash
# 编出来的 App 里的图标（AppIcon.icns）画成 PNG，看是不是新的。
cd "$(dirname "$0")/../.."
sips -s format png .build/Build/Products/Debug/Eyeline.app/Contents/Resources/AppIcon.icns --resampleWidth 256 --out .dev/icon-built.png >/dev/null 2>&1 && ls -la .dev/icon-built.png
