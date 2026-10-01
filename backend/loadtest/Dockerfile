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
    RUNTIME="3m" \
    GEN_WORKERS="1"

# GEN_WORKERS>1 = distributed mode inside the same container: one master
# plus N worker PROCESSES (one Python process = one core, and a single
# gevent loop pegged at 2500 sims — client-side "Connection refused" was
# the generator drowning, not the server). Users are divided across the
# workers automatically; WORKER_ID namespaces their synthetic accounts.
# Locust exits 1 on failures and Railway then re-ran the test back-to-back
# forever — the trailing sleep keeps the container alive (one run per
# deploy); the next run happens on the next redeploy.
CMD if [ "$GEN_WORKERS" -gt 1 ]; then \
      locust -f locustfile.py --host "$TARGET" --master --expect-workers "$GEN_WORKERS" \
        --users "$USERS" --spawn-rate "$SPAWN" --run-time "$RUNTIME" --headless --only-summary & \
      MASTER_PID=$!; \
      i=1; while [ $i -le "$GEN_WORKERS" ]; do \
        WORKER_ID=$i locust -f locustfile.py --host "$TARGET" --worker --master-host 127.0.0.1 & \
        i=$((i+1)); \
      done; \
      wait $MASTER_PID; \
    else \
      locust -f locustfile.py --host "$TARGET" --users "$USERS" --spawn-rate "$SPAWN" --run-time "$RUNTIME" --headless --only-summary; \
    fi ; sleep infinity
