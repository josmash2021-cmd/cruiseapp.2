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

# name: (voice, line, how to say it). Voices picked by ear by the owner
# (2026-11-03): Spanish "marin", English "shimmer".
CLIPS = {
    "rider_stop_es.mp3": (
        "marin",
        "Tu pasajero tiene una parada en el camino.",
        "Voz cálida, amable y tranquila, como si sonrieras al hablar; una "
        "asistente de viaje premium que le avisa algo útil al conductor. "
        "Español latinoamericano neutro, pronunciación clara, ritmo pausado "
        "y entonación natural que baja suave al final. Nada robótico ni "
        "apurado.",
    ),
    "rider_stop_en.mp3": (
        "shimmer",
        "Your rider has a stop along the way.",
        "Warm, friendly and relaxed, as if smiling while speaking; a premium "
        "ride assistant giving the driver a helpful heads-up. Clear "
        "American English, unhurried pace, natural intonation that settles "
        "softly at the end. Never robotic or rushed.",
    ),
}

os.makedirs(OUT, exist_ok=True)
for name, (voice, text, how) in CLIPS.items():
    r = httpx.post(
        "https://api.openai.com/v1/audio/speech",
        headers={"Authorization": f"Bearer {key}"},
        json={
            "model": "gpt-4o-mini-tts",
            "voice": voice,
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
