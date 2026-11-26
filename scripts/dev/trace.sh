#!/bin/bash
# Eyeline 自己打的日志（最近几分钟）。
log show --last ${MINUTES:-5}m --style compact --predicate 'subsystem == "com.omniomo.eyeline"' 2>/dev/null | cut -c1-220 | tail -80
echo "--- takes"; ls -la ~/Movies/Eyeline
