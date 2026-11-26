#!/bin/bash
# 恢复后：导出这次编译的声明（DWARF），放到 .dev/recover-check，跟 .dev/recover（2:32 那次）比。
cd "$(dirname "$0")/../.."
out=.dev/recover-check
mkdir -p $out
app=.build/Build/Intermediates.noindex/Eyeline.build/Debug/Eyeline.build/Objects-normal/arm64
for o in $app/*.o; do
  n=$(basename "$o" .o)
  [ "$n" = GeneratedAssetSymbols ] && continue
  xcrun dwarfdump --debug-info "$o" > /tmp/eyeline-dw.txt 2>/dev/null
  python3 scripts/dev/recover_dw.py /tmp/eyeline-dw.txt "$n.swift" > "$out/$n.decl.txt"
done
ls $out | wc -l
