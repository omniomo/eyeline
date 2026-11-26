#!/bin/bash
# 用 Xcode 自带的 ictool 把图标渲染成 PNG（Liquid Glass 的真实效果）：
# App 用的 Sources/Resources/AppIcon.icon → tools/icon-1024.png；试稿 .dev/icon-work/*/AppIcon.icon → 旁边的 render.png。
cd "$(dirname "$0")/../.."
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
render() { "$IC" "$1" --export-image --output-file "$2" --platform macOS --rendition "${3:-Default}" --width 1024 --height 1024 --scale 1 >/dev/null 2>&1 && echo "$2"; }
render Sources/Resources/AppIcon.icon tools/icon-1024.png
for d in .dev/icon-work/*/AppIcon.icon; do
  dir=$(dirname "$d")
  render "$d" "$dir/render.png"
  render "$d" "$dir/render-dark.png" Dark
done
