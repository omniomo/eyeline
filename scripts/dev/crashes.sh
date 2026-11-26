#!/bin/bash
# 每个崩溃报告：时间、异常、崩溃线程最上面几个和 SwiftUI / AVKit / Eyeline 有关的帧。
for f in $(ls -t ~/Library/Logs/DiagnosticReports/Eyeline* 2>/dev/null | head -6); do
python3 - "$f" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
head, _, body = raw.partition('\n')
r = json.loads(body)
imgs = r.get('usedImages', [])
t = r['threads'][r.get('faultingThread', 0)]
names = []
for fr in t['frames']:
    i = fr.get('imageIndex')
    n = imgs[i]['name'] if i is not None and i < len(imgs) else '?'
    if n in ('Eyeline', 'Eyeline.debug.dylib', '_AVKit_SwiftUI', 'AVKit') or 'Eyeline' in n:
        names.append(f"{n}:{fr.get('symbol','?')}")
print(r.get('captureTime'), r.get('exception', {}).get('type'), r.get('exception', {}).get('signal'))
print('   ', ' | '.join(names[:8]))
PY
done
