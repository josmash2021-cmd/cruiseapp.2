"""Guardian: el payout semanal cura el Connect id ANTES de reclamar.

2026-10-16 — driver 54: su acct_ vivía en OTRA plataforma Stripe, el
transfer rebotaba PermissionError cada lunes (8 cashouts 'failed' en la
corrida del 12-oct) y nunca cobraba. Los endpoints de attach ya curaban vía
`_usable_connect_id`; `_payout_one_driver` usaba el id pelado. Si la
curación vuelve a salir de este camino, el dinero vuelve a no caer.
"""

import inspect

import main


def test_weekly_payout_heals_the_connect_id_before_claiming():
    src = inspect.getsource(main._payout_one_driver)
    heal = src.find("_usable_connect_id")
    claim = src.find('status="processing"')
    assert heal != -1, "el payout ya no cura el connect id"
    assert claim != -1, "no se encontró el claim del cashout"
    assert heal < claim, "la curación debe ir ANTES de reclamar el balance"
    assert "skipping this run" in src, (
        "si la curación falla se salta al driver con el balance intacto")


def test_heal_failure_keeps_balance_untouched():
    """Si el heal explota, el driver NO se reclama: return antes del claim
    (el balance queda para la próxima corrida en vez de quedar clavado en
    'processing')."""
    src = inspect.getsource(main._payout_one_driver)
    heal_block = src[src.find("except Exception as e:"):]
    assert "return" in heal_block.split("CLAIM")[0]
