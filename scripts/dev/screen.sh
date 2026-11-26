#!/bin/bash
# 截一张整个屏幕（看真实的样子；要「录屏」权限）。
cd "$(dirname "$0")/../.."
screencapture -x .dev/screen.png 2>&1
ls -la .dev/screen.png
