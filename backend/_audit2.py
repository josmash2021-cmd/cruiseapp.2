"""Security audit - ASCII only, no emoji"""
import sys, os, time, secrets
os.environ.setdefault('API_KEY',     'test_api_key_1234567890abcdef1234567890abcdef')
os.environ.setdefault('HMAC_SECRET', 'test_hmac_secret_1234567890abcdef1234567890ab')
os.environ.setdefault('JWT_SECRET',  'test_jwt_secret_1234567890abcdef1234567890abc')
os.environ.setdefault('DATABASE_URL','sqlite+aiosqlite:///./test_audit.db')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from utils.security import (
    _PATH_TRAVERSAL_PATTERN, _SQL_INJECTION_PATTERN, _XSS_PATTERN,
    _CMD_INJECTION_PATTERN, _SSRF_INTERNAL_PATTERN, _MALICIOUS_UA_PATTERN,
    _sanitize_string, _check_ssrf, _check_malicious_user_agent,
    _check_login_throttle, _record_login_failure, _clear_login_failures,
    _check_nonce_replay, _is_jti_revoked_memory, _add_revoked_jti,
    _check_password_reset_rate, _record_password_reset,
    _record_violation, _ip_blacklist, _ip_violations,
    _security_audit_log, _audit_chain,
    _create_token, JWT_SECRET, JWT_ALGORITHM,
)
from jose import jwt
from fastapi import HTTPException

passed = 0
failed = 0
issues = []

def chk(name, ok):
    global passed, failed
    if ok:
        passed += 1
        print(f'  PASS  {name}')
    else:
        failed += 1
        issues.append(name)
        print(f'  FAIL  {name}')

print()
print('='*60)
print('CRUISEAPP SECURITY AUDIT v2')
print('='*60)

# --- 1. SQL INJECTION ---
print('\n[1] SQL INJECTION')
chk('OR bypass',    bool(_SQL_INJECTION_PATTERN.search("' OR '1'='1")))
chk('DROP TABLE',   bool(_SQL_INJECTION_PATTERN.search("1; DROP TABLE users--")))
chk('UNION SELECT', bool(_SQL_INJECTION_PATTERN.search("1 UNION SELECT * FROM users")))
chk('Time-based',   bool(_SQL_INJECTION_PATTERN.search("1' AND SLEEP(5)--")))
chk('DELETE all',   bool(_SQL_INJECTION_PATTERN.search("DELETE FROM trips WHERE 1=1")))
chk('xp_cmdshell',  bool(_SQL_INJECTION_PATTERN.search("EXEC xp_cmdshell('dir')")))
chk('OR 1=1',       bool(_SQL_INJECTION_PATTERN.search("' OR 1=1--")))
# no false positives
chk('Normal name (no FP)',    not bool(_SQL_INJECTION_PATTERN.search("John Doe")))
chk('Email (no FP)',          not bool(_SQL_INJECTION_PATTERN.search("user@example.com")))
chk('Address (no FP)',        not bool(_SQL_INJECTION_PATTERN.search("123 Main St Miami")))

# --- 2. XSS ---
print('\n[2] XSS')
chk('<script>',        bool(_XSS_PATTERN.search("<script>alert(1)</script>")))
chk('javascript:',     bool(_XSS_PATTERN.search("javascript:alert(1)")))
chk('img onload',      bool(_XSS_PATTERN.search("<img onload=alert(1)>")))
chk('JAVASCRIPT: cap', bool(_XSS_PATTERN.search("JAVASCRIPT:alert(1)")))
chk('onclick=',        bool(_XSS_PATTERN.search("onclick=alert(1)")))

# --- 3. PATH TRAVERSAL ---
print('\n[3] PATH TRAVERSAL')
chk('../ unix',           bool(_PATH_TRAVERSAL_PATTERN.search("../../etc/passwd")))
chk('..\\windows',       bool(_PATH_TRAVERSAL_PATTERN.search("..\\..\\windows")))
chk('%2e%2e',            bool(_PATH_TRAVERSAL_PATTERN.search("%2e%2e%2fetc")))
chk('..%2F mixed',       bool(_PATH_TRAVERSAL_PATTERN.search("..%2F..%2Fetc%2Fshadow")))
chk('%252e double-enc',  bool(_PATH_TRAVERSAL_PATTERN.search("%252e%252e%252f")))
chk('legit path (no FP)',not bool(_PATH_TRAVERSAL_PATTERN.search("/home/user/photo.jpg")))

# --- 4. SSRF ---
print('\n[4] SSRF PREVENTION')
chk('localhost',        _check_ssrf("http://localhost/admin"))
chk('127.0.0.1',        _check_ssrf("http://127.0.0.1:8080"))
chk('192.168.x',        _check_ssrf("http://192.168.1.1/router"))
chk('10.0.0.x',         _check_ssrf("http://10.0.0.1/internal"))
chk('file://',          _check_ssrf("file:///etc/passwd"))
chk('gopher://',        _check_ssrf("gopher://evil.com"))
chk('169.254 metadata', _check_ssrf("http://169.254.169.254/metadata"))
chk('172.16.x.x',       _check_ssrf("http://172.16.0.1/internal"))
chk('Stripe (no FP)',   not _check_ssrf("https://api.stripe.com/v1/charges"))
chk('Google (no FP)',   not _check_ssrf("https://maps.googleapis.com/maps"))

# --- 5. COMMAND INJECTION ---
print('\n[5] COMMAND INJECTION')
chk('; rm -rf', bool(_CMD_INJECTION_PATTERN.search("; rm -rf /")))
chk('| cat',    bool(_CMD_INJECTION_PATTERN.search("| cat /etc/passwd")))
chk('$(...)',    bool(_CMD_INJECTION_PATTERN.search("$(whoami)")))
chk('eval',     bool(_CMD_INJECTION_PATTERN.search("test eval bash")))
chk('/etc/',    bool(_CMD_INJECTION_PATTERN.search("open /etc/passwd")))

# --- 6. MALICIOUS UA ---
print('\n[6] MALICIOUS UA DETECTION')
chk('sqlmap',    _check_malicious_user_agent("sqlmap/1.7.9"))
chk('nikto',     _check_malicious_user_agent("Nikto/2.1.6"))
chk('nuclei',    _check_malicious_user_agent("nuclei/2.9.0"))
chk('gobuster',  _check_malicious_user_agent("gobuster/3.1.0"))
chk('wfuzz',     _check_malicious_user_agent("wfuzz/3.1.0"))
chk('iPhone (no FP)', not _check_malicious_user_agent("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0)"))
chk('Flutter (no FP)',not _check_malicious_user_agent("Dart/3.0 (dart:io)"))
chk('Chrome (no FP)', not _check_malicious_user_agent("Mozilla/5.0 Chrome/110.0.0.0"))
chk('requests 2.31 (no FP)', not _check_malicious_user_agent("python-requests/2.31.0"))

# --- 7. BRUTE FORCE ---
print('\n[7] BRUTE FORCE PROTECTION')
ip = '9.9.9.9'
_clear_login_failures(ip)
chk('Not blocked at 0',  not _check_login_throttle(ip))
for i in range(4):
    _record_login_failure(ip)
chk('Not blocked at 4',  not _check_login_throttle(ip))
_record_login_failure(ip)
chk('Blocked at 5',      _check_login_throttle(ip))
_clear_login_failures(ip)
chk('Unblocked on clear',not _check_login_throttle(ip))

# --- 8. NONCE REPLAY ---
print('\n[8] NONCE REPLAY')
n = secrets.token_hex(16)
chk('First use OK',  not _check_nonce_replay(n))
chk('Replay blocked', _check_nonce_replay(n))
n2 = secrets.token_hex(16)
chk('New nonce OK',  not _check_nonce_replay(n2))

# --- 9. JWT REVOCATION ---
print('\n[9] JWT REVOCATION')
jti = secrets.token_hex(16)
chk('Not revoked before', not _is_jti_revoked_memory(jti))
_add_revoked_jti(jti, time.monotonic() + 3600)
chk('Revoked after add',   _is_jti_revoked_memory(jti))
expired_jti = secrets.token_hex(16)
_add_revoked_jti(expired_jti, time.monotonic() - 1)
chk('Expired JTI not flagged', not _is_jti_revoked_memory(expired_jti))
tok = _create_token(999, role='rider', status='active')
pay = jwt.decode(tok, JWT_SECRET, algorithms=[JWT_ALGORITHM])
chk('Token has jti',  'jti' in pay)
chk('Token type=access', pay.get('type') == 'access')

# --- 10. PASSWORD RESET RATE LIMIT ---
print('\n[10] PASSWORD RESET RATE LIMIT')
em = f'rtest_{secrets.token_hex(4)}@test.com'
chk('Not limited at start', not _check_password_reset_rate(em))
for _ in range(3): _record_password_reset(em)
chk('Limited after 3',      _check_password_reset_rate(em))

# --- 11. IP AUTO-BAN ---
print('\n[11] IP AUTO-BAN')
ban_ip = f'201.202.{secrets.token_bytes(1)[0]}.{secrets.token_bytes(1)[0]}'
_ip_blacklist.discard(ban_ip)
for _ in range(19): _record_violation(ban_ip)
chk('Not banned at 19', ban_ip not in _ip_blacklist)
_record_violation(ban_ip)
chk('Banned at 20', ban_ip in _ip_blacklist)

# --- 12. CREDENTIAL STUFFING ---
print('\n[12] CREDENTIAL STUFFING DIRECT BAN')
cs_ip = f'100.200.{secrets.token_bytes(1)[0]}.1'
_clear_login_failures(cs_ip)
_ip_blacklist.discard(cs_ip)
for i in range(10):
    _record_login_failure(cs_ip, f'victim{i}@gmail.com')
chk('Banned after 10 unique accounts', cs_ip in _ip_blacklist)

# --- 13. AUDIT HASH CHAIN ---
print('\n[13] AUDIT LOG HASH CHAIN')
init_len = len(_audit_chain)
_security_audit_log('test', '1.2.3.4', 'audit1')
_security_audit_log('test', '1.2.3.4', 'audit2')
chk('Log grows',      len(_audit_chain) > init_len)
if len(_audit_chain) >= 2:
    e1, e2 = _audit_chain[-2], _audit_chain[-1]
    chk('Chain linked', e2['prev'] == e1['hash'])
    chk('Hash 64 chars', len(e2['hash']) == 64)

# --- 14. SANITIZE_STRING ---
print('\n[14] _sanitize_string() BLOCKS ATTACKS')
for label, val in [
    ('SQLi',           "' UNION SELECT * FROM users--"),
    ('XSS',            "<script>alert(1)</script>"),
    ('PathTraversal',  "../../etc/passwd"),
]:
    try:
        _sanitize_string(val)
        chk(f'Blocks {label}', False)
    except HTTPException:
        chk(f'Blocks {label}', True)

for s in ['John Doe', 'user@example.com', 'Miami FL', '8005551234']:
    try:
        _sanitize_string(s)
        chk(f'Allows legit: {s}', True)
    except Exception:
        chk(f'Allows legit: {s}', False)

# SUMMARY
print()
print('='*60)
print(f'PASSED: {passed}   FAILED: {failed}')
if issues:
    print('ISSUES:')
    for x in issues: print(f'  - {x}')
else:
    print('ALL CHECKS PASSED - Server is hardened.')
print('='*60)
sys.exit(1 if failed else 0)
