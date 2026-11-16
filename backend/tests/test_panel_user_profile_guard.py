"""Panel: the Lyft-style person page (owner 2026-11-16, drawing
https://claude.ai/artifact/FrBPF6VbtsioBEzWUMLJT6).

The bundles are patched by hand (CLAUDE.md #30). The new page WRAPS the old
cards instead of replacing them, so every old button keeps working; these
pins fail if a rebuild drops the wiring or a card goes missing.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
CHUNK = (ASSETS / "user-profile-Cruise2026.js").read_text(encoding="utf-8")
PERSON = (ASSETS / "index-azyIyM-i.js").read_text(encoding="utf-8")


def test_person_page_mounts_the_shell_with_a_fallback():
    assert "guard-pin panel_user_profile" in PERSON
    assert 'import("./user-profile-Cruise2026.js").then(x=>({default:x.ProfileShell}))' in PERSON
    # A chunk that fails to load or throws shows the old page, never a blank.
    assert "class UserProfileBoundary extends m.Component" in PERSON
    assert "return this.state.failed?this.props.fallback:this.props.children" in PERSON
    assert "e.jsx(m.Suspense,{fallback:old,children:e.jsx(UserProfileLazy,{...p})})" in PERSON
    assert PERSON.count("return e.jsxs(UserProfileShell,{cruiseRole:t,cruiseId:c,") == 1


def test_every_old_card_has_a_tab():
    titles = set(re.findall(r'e\.jsx\(z,\{icon:[\w$]+,title:"([^"]+)"', PERSON))
    assert {"Información de cuenta", "Vehículo", "Métodos de pago", "Historial de cambios"} <= titles
    rider = re.search(r"const RIDER_HOME=\{(.*?)\};", CHUNK).group(1)
    driver = re.search(r"const DRIVER_HOME=\{(.*?)\};", CHUNK).group(1)
    for title in titles:
        # An unmapped card would still land in Cuenta, but each one should
        # have its place on purpose.
        assert f'"{title}":' in driver, title
        if title not in {"Vehículo", "Banco y pagos", "Rendimiento", "Ganancias", "Sobre el driver"}:
            assert f'"{title}":' in rider, title
    assert 'const k=home[title]||"cuenta"' in CHUNK
    # Dialogs and the re-auth prompt have no title: they always render.
    assert "if(title===null){always.push(c);return}" in CHUNK


def test_deleted_accounts_only_under_eliminados():
    assert 'case"todos":return t.filter(a=>!ge.has(a.status));' in PERSON
    assert 'ge=new Set(["deleted","pending_deletion"])' in PERSON


def test_chunk_uses_real_endpoints_only():
    for path in ("/admin/users/${id}/profile?limit=", "/admin/users/${id}/notes", "/admin/users/${id}/chats",
                 "/admin/users/${id}/support-chat", "/admin/trips/${pick.id}/reassign",
                 "/admin/drivers/${driverId}/payout", "/viajes/viaje/sql_${t.id}", "/viajes/nuevo"):
        assert path in CHUNK, path
    assert '{mode:"driver",driver_id:driverId}' in CHUNK
    assert "bookingPrefill:{rider:{id," in CHUNK
    # A one-click money move never retries on its own.
    assert "/payout`,{},{retry:{maxAttempts:1}}" in CHUNK


def test_backend_routes_are_registered_once():
    main = (Path(__file__).resolve().parents[1] / "main.py").read_text(encoding="utf-8")
    assert "app.include_router(admin_user_profile_router)" in main
    routers = Path(__file__).resolve().parents[1] / "routers"
    hits = [p.name for p in routers.glob("*.py")
            if '"/admin/users/{user_id}/profile"' in p.read_text(encoding="utf-8")]
    assert hits == ["admin_user_profile.py"]


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_chunks_parse(tmp_path):
    for name in ("user-profile-Cruise2026.js", "index-azyIyM-i.js"):
        copy = tmp_path / (name + ".mjs")
        copy.write_text((ASSETS / name).read_text(encoding="utf-8"), encoding="utf-8")
        r = subprocess.run(["node", "--check", str(copy)], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
