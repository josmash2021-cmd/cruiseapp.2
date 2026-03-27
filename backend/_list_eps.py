import re
with open("main.py", "r", encoding="utf-8") as f:
    lines = f.readlines()
eps = []
for i, line in enumerate(lines, 1):
    m = re.search(r'@app\.(get|post|patch|delete|put)\("(/[^"]+)"', line)
    if m:
        eps.append((i, m.group(1).upper(), m.group(2)))
groups = {}
for ln, meth, path in eps:
    parts = path.strip("/").split("/")
    prefix = parts[0] if parts else "root"
    groups.setdefault(prefix, []).append((ln, meth, path))
for prefix in sorted(groups.keys()):
    items = groups[prefix]
    print(f"\n{prefix} ({len(items)} endpoints):")
    for ln, meth, path in items:
        print(f"  L{ln}: {meth} {path}")
print(f"\nTotal: {len(eps)} endpoints")
