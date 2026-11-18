"""The panel opens fast on a phone and never flashes the old pages (owner
2026-11-18: "hay páginas del panel que cuando está cargando en segundos carga
la vieja" / "en teléfono tarda en cargar, a veces tengo que cerrar y volver
abrir varias veces").

- Boot: the role of the last session is used at once and confirmed behind;
  a network error retries instead of the "Sin acceso" screen that only a
  restart cleared. A real "permission-denied" still says Sin acceso.
- The new pages' files download as soon as the panel is idle.
- While a page's file downloads: a spinner, never the old page.
- A slow first answer retries; the old Inicio / old trip cards only after
  three misses in a row."""
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"


def _read(name: str) -> str:
    return (ASSETS / name).read_text(encoding="utf-8")


def test_boot_uses_the_cached_role_and_retries_network_errors():
    src = _read("index-CuQT_62K.js")
    assert "guard-pin panel_role_cache" in src
    assert "cruiseRoleRead(r.uid)?{status:\"authenticated\",user:r,role:cruiseRoleRead(r.uid),roleResolved:!0}" in src
    # The old one-shot check that turned any hiccup into "Sin acceso":
    assert "catch{e({role:null,roleResolved:!0})}" not in src
    assert 'err.code==="permission-denied"' in src
    assert "cruiseRoleForget()" in src  # sign-out forgets it


def test_the_new_pages_are_warmed_up():
    src = _read("index-CuQT_62K.js")
    i = src.index("guard-pin panel_chunk_warmup")
    warm = src[i:i + 1200]
    for chunk in ("home-Cruise2026.js", "trips-board-Cruise2026.js",
                  "support-inbox-Cruise2026.js", "fleet-map-Cruise2026.js",
                  "trip-page-Cruise2026.js", "user-profile-Cruise2026.js"):
        assert chunk in warm, chunk


def test_no_old_page_while_a_file_downloads():
    trip = _read("index-B68rRA9U.js")
    assert "a.Suspense,{fallback:old" not in trip
    profile = _read("index-azyIyM-i.js")
    assert "m.Suspense,{fallback:old" not in profile


def test_a_slow_answer_retries_before_the_old_page():
    home = _read("home-Cruise2026.js")
    assert "if(!data&&failed>=3)return fallback;" in home
    assert "let homeMemo=null;" in home
    trip = _read("trip-page-Cruise2026.js")
    assert "if(fails.current>=3)setErr(" in trip
