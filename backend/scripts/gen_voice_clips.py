"""Generate the driver app's spoken clips (es / en) with OpenAI TTS.

The app plays them from /static/voice/ (lib/services/rider_stop_voice.dart);
an OTA patch cannot add assets, so they live on the backend. Run from the
repo root through `railway run` so OPENAI_API_KEY comes from the service
env — the key is never printed:

    railway run python backend/scripts/gen_voice_clips.py backend/static/voice
"""
import os
import sys

import httpx

OUT = sys.argv[1]
key = os.environ.get("OPENAI_API_KEY", "")
if not key:
    sys.exit("no OPENAI_API_KEY in env")

CLIPS = {
    "rider_stop_es.mp3": (
        "Tu pasajero tiene una parada.",
        "Habla en español latinoamericano neutro, claro, cálido y tranquilo, "
        "como la voz de un navegador GPS. Ritmo natural, sin prisa.",
    ),
    "rider_stop_en.mp3": (
        "Your rider has a stop.",
        "Speak in clear, warm, calm American English, like a GPS navigation "
        "voice. Natural pace, not rushed.",
    ),
}

os.makedirs(OUT, exist_ok=True)
for name, (text, how) in CLIPS.items():
    r = httpx.post(
        "https://api.openai.com/v1/audio/speech",
        headers={"Authorization": f"Bearer {key}"},
        json={
            "model": "gpt-4o-mini-tts",
            "voice": "coral",
            "input": text,
            "instructions": how,
            "response_format": "mp3",
        },
        timeout=60,
    )
    if r.status_code != 200:
        sys.exit(f"{name}: HTTP {r.status_code} {r.text[:200]}")
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(r.content)
    print(name, len(r.content), "bytes")
