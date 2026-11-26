import re, sys
# 从 .o 里挑出看得懂的字符串（UTF-8，至少 4 个字），按出现的顺序，去重。
data = open(sys.argv[1], 'rb').read()
seen = set()
for m in re.finditer(rb'(?:[\x20-\x7e\t\n]|[\xc2-\xdf][\x80-\xbf]|[\xe0-\xef][\x80-\xbf]{2}|[\xf0-\xf4][\x80-\xbf]{3}){4,}', data):
    s = m.group(0).decode('utf-8', 'replace')
    if s in seen or s.startswith('$s') or s.startswith('_$s') or s.startswith('l_') or s.startswith('ltmp'): continue
    seen.add(s)
    print(repr(s))
