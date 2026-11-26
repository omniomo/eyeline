#!/bin/bash
# 稿子库里有哪些稿子：标题、字数、开头几行、有没有加粗。
python3 - <<'PY'
import json, os, re
p = os.path.expanduser('~/Library/Application Support/Eyeline/Scripts.json')
data = json.load(open(p))
docs = data if isinstance(data, list) else data.get('documents', data)
print(type(data).__name__, len(docs))
for d in docs[:8]:
    t = d.get('text', '')
    print('---', len(t), 'chars, bold:', len(re.findall(r'\*\*(.+?)\*\*', t)))
    print('\n'.join(t.splitlines()[:6])[:400])
PY
