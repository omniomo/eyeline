#!/bin/bash
# Eyeline 最近几分钟打的日志里，含某些字的（.dev/grep 第一行：几分钟，第二行：正则）。
log show --last "$(sed -n 1p .dev/grep)m" --style compact --predicate 'process == "Eyeline"' 2>/dev/null | grep "eyeline:app" | grep -E "$(sed -n 2p .dev/grep)" | cut -c12-23,92-330 | tail -60
