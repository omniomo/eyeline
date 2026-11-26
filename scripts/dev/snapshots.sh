#!/bin/bash
# 看看有没有 Time Machine 的本地快照可以找回文件。
tmutil listlocalsnapshots / 2>&1 | tail -20
tmutil latestbackup 2>&1 | tail -2
