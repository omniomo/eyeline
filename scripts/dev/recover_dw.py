import re, sys
# 读 dwarfdump --debug-info 的输出，按源文件列出声明：行号、种类、名字、类型。
src = sys.argv[1]
want = sys.argv[2]  # 源文件名，比如 Prompter.swift
entries = []
cur = None
depth_stack = []
for line in open(src, errors='replace'):
    m = re.match(r'^0x[0-9a-f]+:(\s+)(DW_TAG_\w+)', line)
    if m:
        if cur: entries.append(cur)
        cur = {'tag': m.group(2)[7:], 'indent': len(m.group(1))}
        continue
    if cur is None: continue
    a = re.match(r'^\s+(DW_AT_\w+)\s+\((.*)\)\s*$', line)
    if a:
        k, v = a.group(1)[6:], a.group(2)
        if k in ('name', 'decl_file', 'decl_line', 'type', 'linkage_name'):
            cur[k] = v
if cur: entries.append(cur)
rows = []
for e in entries:
    f = e.get('decl_file', '')
    if not f.strip('"').endswith('/' + want): continue
    if 'decl_line' not in e: continue
    name = e.get('name', '').strip('"')
    typ = e.get('type', '')
    tm = re.search(r'"([^"]*)"', typ)
    typ = tm.group(1) if tm else ''
    rows.append((int(e['decl_line']), e['indent'], e['tag'], name, typ))
seen = set()
for r in sorted(rows):
    key = (r[0], r[2], r[3])
    if key in seen: continue
    seen.add(key)
    print(f"{r[0]:5d} {'  '*max(0,(r[1]-1)//2)}{r[2]:<20} {r[3]}  : {r[4]}")
