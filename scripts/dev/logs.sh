#!/bin/bash
# 最近 Eyeline 的日志，去掉系统的杂音。
log show --last ${MINUTES:-6}m --style compact --predicate 'process == "Eyeline"' 2>/dev/null \
  | grep -vE "StateRestoration|CoreAnalytics|xpc:|RunningBoard|LaunchServices|SkyLight|BackgroundTask|Bootstrap" \
  | grep -iE "terminat|quit|AppleEvent|error|fault|crash|exception|speech|audio|Eyeline\]" | head -80
