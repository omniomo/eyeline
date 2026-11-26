#!/bin/bash
# 源代码被旧的同步包盖掉了：从最后一次编译的 .o 里找回每个文件的结构（DWARF：声明和行号）和字符串常量。
cd "$(dirname "$0")/../.."
out=.dev/recover
mkdir -p $out
app=.build/Build/Intermediates.noindex/Eyeline.build/Debug/Eyeline.build/Objects-normal/arm64
tests=.build/Build/Intermediates.noindex/Eyeline.build/Debug/EyelineTests.build/Objects-normal/arm64
for o in $app/*.o $tests/CueTests.o $tests/TrackerTests.o; do
  n=$(basename "$o" .o)
  [ "$n" = GeneratedAssetSymbols ] && continue
  tag=$n; case "$o" in *EyelineTests*) tag="test-$n";; esac
  xcrun dwarfdump --debug-info "$o" > /tmp/eyeline-dw.txt 2>/dev/null
  python3 scripts/dev/recover_dw.py /tmp/eyeline-dw.txt "$n.swift" > "$out/$tag.decl.txt"
  python3 scripts/dev/recover_str.py "$o" > "$out/$tag.str.txt"
  ls -la /tmp/eyeline-dw.txt | awk -v n="$tag" '{print n, $5}'
done
wc -l $out/*.txt | tail -40
