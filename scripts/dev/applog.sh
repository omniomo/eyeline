#!/bin/bash
# 最近 5 分钟 Eyeline 自己打的日志（Log.info）。
log show --last 5m --style compact --predicate 'process == "Eyeline"' 2>/dev/null > .dev/applog-raw.txt
wc -l < .dev/applog-raw.txt
grep -c "com.omniomo.eyeline" .dev/applog-raw.txt
grep "com.omniomo.eyeline" .dev/applog-raw.txt | cut -c1-200 | tail -20
pgrep -lx Eyeline || echo "not running"
