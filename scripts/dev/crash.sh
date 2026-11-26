#!/bin/bash
# 最近一次崩溃：异常、崩在哪个线程、那个线程的调用栈（只看 Eyeline 自己的帧和前后几帧）。
latest=$(ls -t ~/Library/Logs/DiagnosticReports/Eyeline* 2>/dev/null | head -1)
[ -z "$latest" ] && { echo "no crash report"; exit 0; }
echo "$latest  ($(stat -f %Sm "$latest"))"
python3 - "$latest" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
head, _, body = raw.partition('\n')
r = json.loads(body)
print('exception:', json.dumps(r.get('exception')), json.dumps(r.get('termination', {}).get('indicator')))
for k in ('asi', 'lastExceptionBacktrace'):
    if k in r: print(k, ':', json.dumps(r[k])[:1500])
imgs = r.get('usedImages', [])
t = r['threads'][r.get('faultingThread', 0)]
print('thread', r.get('faultingThread'), t.get('queue', ''), t.get('name', ''))
for f in t['frames'][:40]:
    img = imgs[f['imageIndex']]['name'] if f.get('imageIndex') is not None and f['imageIndex'] < len(imgs) else '?'
    print(f"  {img:28} {f.get('symbol', '?')}  {f.get('sourceFile', '')}:{f.get('sourceLine', '')}")
PY
