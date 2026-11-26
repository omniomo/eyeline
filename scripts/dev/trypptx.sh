#!/bin/bash
# 试 PowerPoint：单独的稿子库里拖进 .dev/deck-image.pptx，看页面（Quick Look 画的）和备注，然后按原样重新打开。
cd "$(dirname "$0")/../.."
rm -rf .dev/teststore && mkdir -p .dev/teststore
pkill -x Eyeline && sleep 0.5
rm -f .dev/deck-pptx.png
open -n .build/Build/Products/Debug/Eyeline.app --args -storeFolder "$PWD/.dev/teststore" -recordTakes NO -showSlides YES \
  -pptxTest "$PWD/.dev/${1:-deck-image}.pptx" -deckShot "$PWD/.dev/deck.png"
sleep 14
log show --last 18s --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -E "eyeline:app" | cut -c60-300
ls -la .dev/deck-pptx.png
pkill -x Eyeline && sleep 0.5
args=$(cat .dev/args 2>/dev/null)
open -n .build/Build/Products/Debug/Eyeline.app --args $args
