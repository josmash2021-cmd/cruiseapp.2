"""Backend-hosted onboarding photos (2026-10-23, owner report: las imágenes
nunca llegaron por OTA — los assets nuevos no viajan en parches Shorebird).
El mount /static ahora sirve las 8 fotos de vestimenta y selfie para que la
app las descargue en cualquier build (el asset local es el fallback
offline)."""

import pytest

pytestmark = pytest.mark.asyncio


async def test_onboarding_photos_are_served(client):
    for name in [
        "guide_selfie_vip_m.png",
        "guide_selfie_std_m.png",
        "guide_selfie_vip_f.png",
        "guide_selfie_std_f.png",
        "guide_dress_vip_m.png",
        "guide_dress_std_m.png",
        "guide_dress_vip_f.png",
        "guide_dress_std_f.png",
    ]:
        res = await client.get(f"/static/onboarding/{name}")
        assert res.status_code == 200, name
        assert res.headers["content-type"].startswith("image/png")
        assert len(res.content) > 1000, name
