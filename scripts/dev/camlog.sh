#!/bin/bash
# 摄像头和录像相关的日志。
log show --last ${MINUTES:-10}m --style compact --predicate 'process == "Eyeline"' 2>/dev/null \
  | grep -iE "AVCapture|camera|cmio|movie|record|TCC|denied|error|authoriz|speech|Eyeline ribbon" \
  | grep -vE "coreaudio:AUHAL|HALC_|caulk" | tail -60
pgrep -lx Eyeline
