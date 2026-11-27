#!/bin/bash
# 把 App 装进一个打开就是「拖进应用程序」那个窗口的 dmg：背景图（tools/dmg），图标摆好，没有工具栏。
# 用 dmgbuild 写窗口设置，不用 AppleScript 去点 Finder。第一次会在 .build/dmgbuild 里装一个 Python 环境。
#   scripts/make-dmg.sh <Eyeline.app> <输出.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$1
OUT=$2
VENV=.build/dmgbuild
if ! "$VENV/bin/python" -c "import importlib.metadata as m; assert m.version(\"dmgbuild\") == \"2.0.0\"" 2>/dev/null; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==2.0.0"
fi
WORK=$(mktemp -d /tmp/eyeline-dmg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
# 1x 和 2x 合成一张 tiff，Retina 屏上也清楚
tiffutil -cathidpicheck tools/dmg/background.png tools/dmg/background@2x.png -out "$WORK/background.tiff" >/dev/null
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s tools/dmg/settings.py -D app="$APP" -D background="$WORK/background.tiff" "Eyeline" "$OUT"
