"""Secret scanner as a guardian (2026-10-15, user spec: "que no haya
vulnerabilidad posible"). GitHub's secret scanning costs extra on private
repos — this runs free on every pytest pass: any REAL key shape committed
to the repo fails the suite the same second.

Patterns target secrets only. Publishable-by-design keys (Firebase,
pk_live, Google Maps) ship in the APK/IPA and are NOT matched — their
protection is console-side restrictions, not hiding.
"""

import re
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Real secret shapes. Keep the tails long so doc placeholders never match.
PATTERNS = {
    "OpenAI project key": re.compile(r"sk-proj-[A-Za-z0-9_\-]{40,}"),
    "OpenAI legacy key": re.compile(r"sk-[A-Za-z0-9]{40,}"),
    "Stripe live SECRET key": re.compile(r"sk_live_[A-Za-z0-9]{20,}"),
    "Stripe webhook secret": re.compile(r"whsec_[A-Za-z0-9]{20,}"),
    "Private key block": re.compile(r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"),
    "Slack token": re.compile(r"xox[bapors]-[A-Za-z0-9\-]{20,}"),
}

# Files whose contents legitimately carry look-alikes (templates, docs that
# quote the audit, test fixtures with fake keys).
ALLOWLIST = (
    ".env.example",
    ".env.template",
    "SECURITY_ACTIONS.md",
    "AUDIT_REPORT.md",
    "tests/",  # test fixtures carry synthetic keys
    "test_no_secrets_in_repo.py",
)


def _contains_dispatch_signing_material(text: str) -> bool:
    crypto = "crypto.subtle.importKey" in text and "crypto.subtle.sign" in text
    hmac = bool(re.search(r"[\"']HMAC[\"']", text))
    api_key = bool(re.search(r"[\"']X-API-Key[\"']", text))
    signature = bool(re.search(r"[\"']X-Signature[\"']", text))
    return crypto and hmac and api_key and signature


def _tracked_files():
    out = subprocess.run(
        ["git", "ls-files"], cwd=REPO_ROOT, capture_output=True, text=True,
        check=True,
    )
    return [p for p in out.stdout.splitlines() if p.strip()]


def test_no_real_secrets_are_committed():
    offenders = []
    for rel in _tracked_files():
        if any(rel.startswith(a) or rel.endswith(a) for a in ALLOWLIST):
            continue
        f = REPO_ROOT / rel
        try:
            text = f.read_text(encoding="utf-8", errors="ignore")
        except (OSError, UnicodeError):
            continue
        for name, pat in PATTERNS.items():
            if pat.search(text):
                offenders.append(f"{rel}: {name}")
        if _contains_dispatch_signing_material(text):
            offenders.append(f"{rel}: Dispatch signing material in browser code")
    assert not offenders, (
        "Secret(s) committed to the repo — rotate NOW and purge history:\n"
        + "\n".join(offenders)
    )


def test_dispatch_signing_detector_matches_a_synthetic_bundle():
    fixture = """
    const key = "synthetic-fixture-not-a-credential";
    async function sign(bytes) {
      const keyObject = await crypto.subtle.importKey(
        "raw", key, {name: "HMAC", hash: "SHA-256"}, false, ["sign"]
      );
      return crypto.subtle.sign("HMAC", keyObject, bytes);
    }
    const headers = {"X-API-Key": key, "X-Signature": "synthetic"};
    """
    assert _contains_dispatch_signing_material(fixture)


def test_dispatch_signing_detector_allows_cookie_adapter():
    fixture = """
    async function Yr() { return {Accept: "application/json"}; }
    fetch("/admin/example", {credentials: "same-origin", headers: await Yr()});
    """
    assert not _contains_dispatch_signing_material(fixture)
