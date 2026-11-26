#!/bin/bash
# App 还在不在跑；最近有没有崩溃报告；最近的系统日志。
pgrep -lx Eyeline || echo "not running"
latest=$(ls -t ~/Library/Logs/DiagnosticReports/Eyeline* 2>/dev/null | head -1)
if [ -n "$latest" ]; then
  echo "crash report: $latest ($(stat -f %Sm "$latest"))"
  head -c 6000 "$latest"
fi
log show --last 2m --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -vE "Bootstrap|LaunchServices|Activity|SkyLight|RunningBoard" | tail -40
