FROM python:3.12-slim

# Load generator service (staging only): runs the Locust harness from INSIDE
# the Railway project, against the backend's private address — a laptop at
# home was the bottleneck in the first runs (server metrics were healthy
# while client-measured latency exploded). Results land in the service logs.

WORKDIR /lt
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY locustfile.py .

ENV LT_API_KEY="staging-loadtest-key" \
    LT_HMAC_SECRET="staging-loadtest-hmac" \
    TARGET="http://cruiseapp-staging.railway.internal:8000" \
    USERS="500" \
    SPAWN="50" \
    RUNTIME="3m"

# Locust exits 1 when a run has failures, and Railway's restart policy then
# re-ran the test back-to-back forever — each run starting on a system still
# busy with the previous one's zombie trips, so every result after the first
# was contaminated. The trailing sleep keeps the container alive (one run per
# deploy); the next run happens on the next redeploy.
CMD locust -f locustfile.py --host "$TARGET" --users "$USERS" --spawn-rate "$SPAWN" --run-time "$RUNTIME" --headless --only-summary ; sleep infinity
