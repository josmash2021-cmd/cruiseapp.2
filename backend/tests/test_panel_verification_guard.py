"""Verificación estilo Lyft (dueño 2026-11-18, dibujo
https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H): verification-Cruise2026.js.

Only the layout changes; every decision must stay the SAME call the old page
(index-jhlVlbS1.js) makes. The helpers are copied verbatim from that chunk,
so this test fails as soon as the two drift apart."""
import re
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"


def _read(name: str) -> str:
    return (ASSETS / name).read_text(encoding="utf-8")


def _old_helpers() -> str:
    old = _read("index-jhlVlbS1.js")
    a = old.index("async function ha(e){")
    b = old.index("function Xa({request:e,onClose:t,onReviewed:s}){")
    c = old.index("async function it(){")
    d = old.index('const lt=["","rider","driver"]')
    return re.sub(r"/\*![^*]*\*/", "", old[a:b] + old[c:d])


def test_chunk_exports_the_page_with_its_guard_pin():
    src = _read("verification-Cruise2026.js")
    assert src.startswith("/*! guard-pin panel_verification_queue:")
    assert "export{VerificationQueue};" in src
    # The same live queue as the old page (Firestore + /admin/verifications).
    assert "aA as qe" in src and "qe()" in src


def test_decisions_are_the_old_pages_calls_verbatim():
    src = _read("verification-Cruise2026.js")
    assert _old_helpers() in src, "helpers drifted from index-jhlVlbS1.js"
    for call in ("/auth/dispatch-approve/", "/auth/dispatch-reject/",
                 "/auth/dispatch-waitlist/", "/auth/dispatch-unwaitlist/",
                 "/admin/verifications/${", "/admin/backfill-approved"):
        assert call in src, call
    assert 'n==="unwaitlist"?"pending"' in src  # Firestore mirror mapping
    # Approve / reject / waitlist / quitar go through the copied wrappers.
    for fn in ("()=>Se(req.docId)", "()=>ke(req.docId,", "()=>Ce(req.docId)",
               "()=>unwaitlistMut(req.docId)"):
        assert fn in src, fn


def test_daily_selfies_use_the_face_check_endpoints_only():
    src = _read("verification-Cruise2026.js")
    assert '"/admin/face-checks/pending"' in src
    assert "approveFaceCheck(fc.id)" in src and "rejectFaceCheck(fc.id)" in src
    # selfie_check never reaches the generic /admin/documents/{id}/status.
    assert 'toLowerCase()==="selfie_check")continue' in src


def test_review_flow_as_drawn():
    src = _read("verification-Cruise2026.js")
    assert 'h>24?"red":h>12?"gold":"gray"' in src           # age pills
    assert "vqTs(x.submittedAt,Infinity)-vqTs(z.submittedAt,Infinity)" in src  # oldest first
    assert "if(done)onDecided(req.docId)" in src              # moves on by itself
    assert '"Al decidir, pasa sola a la siguiente persona."' in src
    assert "object-fit:contain" in src                        # the photo is never cropped
    assert '["rider","Pasajeros"],["driver","Conductores"]' in src
    # In-page dialogs only.
    for bad in ("window.prompt", "window.confirm", "alert("):
        assert bad not in src, bad
