#!/usr/bin/env bash
set -euo pipefail

FAILURES=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILURES=$((FAILURES + 1)); }

# 1. container_health — expect 7 healthy containers
count=$(docker compose ps --format json 2>/dev/null \
    | python3 -c "
import sys, json
data = sys.stdin.read().strip()
rows = [json.loads(l) for l in data.splitlines() if l.strip()]
print(sum(1 for r in rows if r.get('Health') == 'healthy'))
" 2>/dev/null || echo 0)
if [ "$count" -ge 7 ]; then
    pass container_health
else
    echo "  healthy containers: $count/7"
    fail container_health
fi

# 2. namenode_ui
if curl -fsS http://localhost:9870/dfshealth.html >/dev/null 2>&1; then
    pass namenode_ui
else
    fail namenode_ui
fi

# 3. resourcemanager_ui
if curl -fsS http://localhost:8088/cluster >/dev/null 2>&1; then
    pass resourcemanager_ui
else
    fail resourcemanager_ui
fi

# 4. live_datanodes — expect >= 2
dn_count=$(docker compose exec -T namenode hdfs dfsadmin -report 2>/dev/null \
    | grep "Live datanodes" | grep -oP '\d+' || echo 0)
if [ "${dn_count:-0}" -ge 2 ]; then
    pass live_datanodes
else
    echo "  live datanodes: ${dn_count:-0}"
    fail live_datanodes
fi

# 5. nodemanagers — expect >= 2
nm_count=$(docker compose exec -T resourcemanager yarn node -list 2>/dev/null \
    | grep -c "RUNNING" || echo 0)
if [ "${nm_count:-0}" -ge 2 ]; then
    pass nodemanagers
else
    echo "  running nodemanagers: ${nm_count:-0}"
    fail nodemanagers
fi

# 6. replication_check — skip if dataset not loaded yet
HDFS_FILE=/user/root/input/NASA_access_log_Jul95
if docker compose exec -T namenode hdfs dfs -test -e "$HDFS_FILE" 2>/dev/null; then
    rep=$(docker compose exec -T namenode hdfs dfs -stat "%r" "$HDFS_FILE" 2>/dev/null || echo 0)
    if [ "${rep:-0}" -ge 2 ]; then
        pass replication_check
    else
        echo "  replication factor: ${rep:-0}"
        fail replication_check
    fi
else
    echo "[SKIP] replication_check (dataset not loaded)"
fi

# 7. mapreduce_smoke — pi 2 5 proves end-to-end MapReduce works
echo "  Running MapReduce smoke test (pi 2 5) — up to 180s..."
smoke_exit=0
timeout 180 docker compose exec -T resourcemanager bash -c \
    'yarn jar $(ls /opt/hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar | head -1) pi 2 5' \
    </dev/null >/tmp/nasa_smoke_pi.txt 2>&1 || smoke_exit=$?
cat /tmp/nasa_smoke_pi.txt
if [ "$smoke_exit" -eq 0 ] && grep -q 'Estimated value of Pi' /tmp/nasa_smoke_pi.txt; then
    grep 'Estimated value of Pi' /tmp/nasa_smoke_pi.txt
    docker compose exec -T resourcemanager hdfs dfs -rm -r -f '/user/root/QuasiMonteCarlo_*' 2>/dev/null || true
    pass mapreduce_smoke
else
    fail mapreduce_smoke
fi

echo ""
echo "Results: $((7 - FAILURES)) passed, $FAILURES failed."
[ "$FAILURES" -eq 0 ]
