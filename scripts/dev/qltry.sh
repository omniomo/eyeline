#!/bin/bash
# 试试系统自带的 Quick Look 能不能把 .pptx 画出来（没装 Keynote / PowerPoint 的时候）。
cd "$(dirname "$0")/../.."
rm -rf .dev/ql; mkdir -p .dev/ql
qlmanage -p -o .dev/ql .dev/deck-image.pptx > .dev/ql/out.txt 2>&1
plutil -p .dev/ql/deck-image.pptx.qlpreview/PreviewProperties.plist >> .dev/ql/out.txt 2>&1
cat .dev/ql/out.txt | tail -5
find .dev/ql -maxdepth 3 | head -30
