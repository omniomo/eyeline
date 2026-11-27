#!/bin/bash
# 试幻灯片：用一个单独的稿子库（.dev/teststore，不碰你的稿子），导入一份 4 页的 PDF，
# 翻页、点稿子、提词、按翻页笔、放映，看日志和截图，然后按原样重新打开。
# .dev/deckargs 里可以加启动参数，比如 -mode steady。
cd "$(dirname "$0")/../.."
pdf="$PWD/.dev/deck-test.pdf"
if [ ! -s "$pdf" ]; then
  printf 'Opening\n\nWhy this talk\fProblem\n\nWhat goes wrong\fSolution\n\nHow we fix it\fThanks\n' > .dev/deck-test.txt
  cupsfilter .dev/deck-test.txt > "$pdf" 2>/dev/null
fi
pdf2="$PWD/.dev/deck-test2.pdf"
if [ ! -s "$pdf2" ]; then
  printf 'Opening\n\nWhy this talk\fA new slide\n\nInserted in between\fProblem\n\nWhat goes wrong\fSolution\n\nHow we fix it\fThanks\n' > .dev/deck-test2.txt
  cupsfilter .dev/deck-test2.txt > "$pdf2" 2>/dev/null
fi
rm -rf .dev/teststore && mkdir -p .dev/teststore
pkill -x Eyeline && sleep 0.5
rm -f .dev/deck*.png
open -n .build/Build/Products/Debug/Eyeline.app --args -storeFolder "$PWD/.dev/teststore" -hideFromCapture NO -recordTakes NO \
  -showSlides YES $(cat .dev/deckargs 2>/dev/null) -deckTest "$pdf" -deckTest2 "$pdf2" -deckShot "$PWD/.dev/deck.png"
sleep 21
log show --last 27s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -E "eyeline:app" | grep -iE "deck|slide|start|caption|paste" | cut -c60-420
log show --last 26s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -iE " E | fault" | cut -c1-200 | tail -5
pgrep -lx Eyeline || echo "not running"
ls -la .dev/deck*.png
pkill -x Eyeline && sleep 0.5
args=$(cat .dev/args 2>/dev/null)
open -n .build/Build/Products/Debug/Eyeline.app --args $args
[ -f .dev/deck-editor.pdf ] && sips -s format png .dev/deck-editor.pdf --out .dev/deck-editor.png >/dev/null 2>&1; ls -la .dev/deck-editor.*
