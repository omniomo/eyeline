#!/bin/bash
# 最近 8 分钟 Eyeline 自己的日志和报错。
log show --last 8m --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep -E "eyeline:app| E |fault|drag|drop|pptx|Dragging" | grep -vE "BoardServices|inputAnalytics|ViewBridge" | grep -iE "${GREP:-.}" | cut -c1-40,90-300 | tail -40
