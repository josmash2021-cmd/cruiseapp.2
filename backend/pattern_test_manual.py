"""Quick pattern test after fixes."""
import os, sys
os.environ.setdefault('API_KEY',     'test_api_key_1234567890abcdef1234567890abcdef')
os.environ.setdefault('HMAC_SECRET', 'test_hmac_secret_1234567890abcdef1234567890ab')
os.environ.setdefault('JWT_SECRET',  'test_jwt_secret_1234567890abcdef1234567890abc')
os.environ.setdefault('DATABASE_URL','sqlite+aiosqlite:///./test_audit.db')
sys.path.insert(0, os.path.dirname(__file__))

import ast
ast.parse(open('utils/security.py', encoding='utf-8').read())
print("Syntax OK")

from utils.security import (
    _PATH_TRAVERSAL_PATTERN, _SQL_INJECTION_PATTERN,
    _record_login_failure, _ip_blacklist, _clear_login_failures,
)

issues = []

# PATH TRAVERSAL
pt_cases = [
    ("Unix ../",           "../etc/passwd",              True),
    ("Windows ..\\ ",      "..\\..\\windows",            True),
    ("%2e%2e",             "%2e%2e%2fetc",               True),
    ("Mixed ..%2F",        "..%2F..%2Fetc%2Fshadow",    True),   # was failing
    ("Double encoded",     "%252e%252e%252f",            True),
    ("Legitimate path",    "/home/user/photos",          False),
    ("Filename with ..",   "my..file.jpg",               False),  # should NOT block
]
print("\n[PATH TRAVERSAL]")
for name, payload, should_block in pt_cases:
    blocked = bool(_PATH_TRAVERSAL_PATTERN.search(payload))
    ok = blocked == should_block
    status = "OK  " if ok else "FAIL"
    print(f"  {status} [{name}] payload={payload!r} blocked={blocked} expected={should_block}")
    if not ok:
        issues.append(f"PathTraversal {name}")

# SQL INJECTION
sqli_cases = [
    ("Classic OR bypass",    "' OR '1'='1",                True),  # was failing
    ("OR 1=1",               "' OR 1=1--",                 True),
    ("Admin bypass",         "admin' OR '1'='1",           True),
    ("DROP TABLE",           "1; DROP TABLE users--",      True),
    ("UNION SELECT",         "1 UNION SELECT * FROM users",True),
    ("DELETE all",           "DELETE FROM trips WHERE 1=1",True),
    ("Normal name",          "John Doe",                   False),
    ("Email",                "user@example.com",           False),
    ("Normal address",       "123 Main Street Miami FL",   False),
]
print("\n[SQL INJECTION]")
for name, payload, should_block in sqli_cases:
    blocked = bool(_SQL_INJECTION_PATTERN.search(payload))
    ok = blocked == should_block
    status = "OK  " if ok else "FAIL"
    print(f"  {status} [{name}] blocked={blocked} expected={should_block}")
    if not ok:
        issues.append(f"SQLi {name}")

# CREDENTIAL STUFFING
print("\n[CREDENTIAL STUFFING -> DIRECT BAN]")
cs_ip = "44.55.66.77"
_clear_login_failures(cs_ip)
cs_ip not in _ip_blacklist or _ip_blacklist.discard(cs_ip)
for i in range(10):
    _record_login_failure(cs_ip, f"victim{i}@gmail.com")
banned = cs_ip in _ip_blacklist
ok = banned
status = "OK  " if ok else "FAIL"
print(f"  {status}  IP banned after 10 unique accounts: {banned}")
if not ok:
    issues.append("Credential stuffing ban")

print()
print("="*50)
print(f"Issues: {len(issues)}")
for i in issues:
    print(f"  FAIL: {i}")
if not issues:
    print("All pattern tests PASSED")
sys.exit(1 if issues else 0)
