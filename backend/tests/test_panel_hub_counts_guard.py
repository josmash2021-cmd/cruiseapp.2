"""Panel "Viajes" hub badges match their lists (2026-11-15).

The Completados / Cancelados badges counted only trips created in the last
7 days (the hub's shared Firestore listener), while tapping the card opens
the history page, which lists EVERY trip with that status. Result: badges at
0 over a list full of trips. The badges now run the history page's own query
(status == X ordered by createdAt). The bundle is patched by hand
(CLAUDE.md #30): these pins fail if a rebuild brings the old counts back.
"""
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
HUB = (ASSETS / "index-B68rRA9U.js").read_text(encoding="utf-8")


def test_history_badges_use_the_history_query():
    assert HUB.count("guard-pin panel_hub_history_counts") == 1
    assert ('Rt(es(ss(Ve,"trips"),kt("status","==",at[k0]),wt("createdAt","desc"))'
            in HUB)
    assert 'count:hc("completed")' in HUB
    assert 'count:hc("cancelled")' in HUB
    assert 'count:o("completed")' not in HUB
    assert 'count:o("cancelled")' not in HUB


def test_hidden_trips_stay_out_of_the_badges():
    # Same filter as the list (Gt): a trip deleted from the panel is not counted.
    assert "hd[k0].filter(id0=>!hx.has(id0)).length" in HUB
    assert "hx=tt(y=>y.hidden.trips)" in HUB


def test_live_badges_keep_their_own_source():
    # Activo / En Proceso open the live list, which reads the same hook.
    assert 'count:o("active")' in HUB
    assert 'count:o("inProgress")' in HUB
