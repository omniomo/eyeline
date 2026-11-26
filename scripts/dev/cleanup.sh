#!/bin/bash
# 删掉临时文件和旧的同步包。
cd "$(dirname "$0")/../.."
rm -f Tests/DebugTrace.swift
ls -t .dev/sync-*.tgz 2>/dev/null | tail -n +2 | xargs rm -f
rm -f .dev/sync.tgz
echo cleaned
