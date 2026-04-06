import ast
import sys

try:
    with open("routers/dispatch.py", encoding="utf-8") as f:
        source = f.read()
    ast.parse(source)
    print("OK - syntax is valid")
except SyntaxError as e:
    print(f"SyntaxError at line {e.lineno}: {e.msg}")
    # Show the problematic line
    lines = source.split("\n")
    if e.lineno and e.lineno <= len(lines):
        line = lines[e.lineno - 1]
        print(f"Line content: {repr(line)}")
        # Find non-ASCII chars
        for i, ch in enumerate(line):
            if ord(ch) > 127:
                print(f"  pos {i}: U+{ord(ch):04X} = {repr(ch)}")
