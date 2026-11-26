#!/bin/bash
# 最近 2 分钟 Eyeline 里跟放视频有关的日志。
log show --last 2m --style compact --predicate 'process == "Eyeline"' 2>/dev/null \
  | grep -iE "AVPlayer|FigPlayer|AVKit|playback|videoplayer|item.*ready|\.mov" | grep -vE "HALC_|caulk" | cut -c1-220 | tail -25
pgrep -lx Eyeline
