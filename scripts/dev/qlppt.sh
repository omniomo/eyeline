#!/bin/bash
# 找到那份打不开的 .ppt（老格式），看 Quick Look 能不能把它画出来、画出来的网页长什么样。
cd "$(dirname "$0")/../.."
f=$(mdfind "kMDItemFSName == '*functions and models*'cd" 2>/dev/null | grep -i "\.ppt$" | head -1)
[ -z "$f" ] && f=$(find ~/Downloads ~/Desktop ~/Documents -maxdepth 4 -iname "*functions and models*.ppt" 2>/dev/null | head -1)
[ -z "$f" ] && f=$(find ~/Downloads ~/Desktop ~/Documents -maxdepth 4 -iname "*.ppt" 2>/dev/null | head -1)
echo "file: $f"
[ -z "$f" ] && exit 0
ls -la "$f"
rm -rf .dev/qlppt; mkdir -p .dev/qlppt
cp "$f" .dev/deck-old.ppt
qlmanage -p -o .dev/qlppt "$f" > .dev/qlppt/out.txt 2>&1
tail -5 .dev/qlppt/out.txt
find .dev/qlppt -maxdepth 3 | head -30
p=$(find .dev/qlppt -name "*.plist" | head -1); [ -n "$p" ] && plutil -p "$p"
h=$(find .dev/qlppt -name "Preview.html" | head -1)
[ -n "$h" ] && { wc -c "$h"; grep -o 'class="[^"]*"' "$h" | sort | uniq -c | sort -rn | head -15; head -c 1500 "$h"; }
