#!/bin/bash
# 从最后一次编译的 MainView.o 里找回结构（DWARF：声明和行号）和字符串常量。
cd "$(dirname "$0")/../.."
out=.dev/recover-main
mkdir -p $out
o=.build/Build/Intermediates.noindex/Eyeline.build/Debug/Eyeline.build/Objects-normal/arm64/MainView.o
ls -la "$o"
xcrun dwarfdump --debug-info "$o" > /tmp/eyeline-mv.txt 2>/dev/null
python3 scripts/dev/recover_dw.py /tmp/eyeline-mv.txt "MainView.swift" > "$out/MainView.decl.txt"
python3 scripts/dev/recover_str.py "$o" > "$out/MainView.str.txt"
wc -l $out/*
