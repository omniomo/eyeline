#!/bin/bash
# 用 `say` 合成一段普通话（中间故意说错重来一句），走一遍「识别 → 跟读」，看位置怎么走。
cd "$(dirname "$0")/../.."
mkdir -p .dev/probe
cat > .dev/probe/script.txt <<'EOS'
如果你需要 mock 一张假聊天截图，
如果你跟我一样，没朋友，⏸
你可能需要 Mimic。
有朋友的人，找个朋友聊两句，截下来就行。
没朋友的人，只能自己跟自己聊。
Mimic 就是让你自己跟自己聊，还聊得特别像。
EOS
say -v Tingting -r 210 -o .dev/probe/read.aiff "如果你需要 mock 一张假聊天截图。如果你跟我一样，没朋友。你可能需要 Mimic。有朋友的人，找个朋友，嗯。有朋友的人，找个朋友聊两句，截下来就行。没朋友的人，只能自己跟自己聊。Mimic 就是让你自己跟自己聊，还聊得特别像。"
rm -f .dev/probe/out.txt
open -W -n .build/Build/Products/Debug/Eyeline.app --args --probe "$PWD/.dev/probe/read.aiff" "$PWD/.dev/probe/script.txt" "$PWD/.dev/probe/out.txt" zh-CN
cat .dev/probe/out.txt
