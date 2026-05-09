#!/usr/bin/env bash
set -euo pipefail

FAILURES=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILURES=$((FAILURES + 1)); }

# 1. container_health
all_ok=true
for c in nasa-namenode nasa-datanode nasa-resourcemanager nasa-nodemanager nasa-historyserver; do
    state=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
    health=$(docker inspect --format '{{.State.Health.Status}}' "$c" 2>/dev/null || echo none)
    if [[ "$state" != "running" || "$health" != "healthy" ]]; then
        echo "  $c: state=$state health=$health"
        all_ok=false
    fi
done
if $all_ok; then pass container_health; else fail container_health; fi

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

# 4. live_datanode — capture output to avoid SIGPIPE on grep -q exit
if report=$(docker compose exec -T namenode hdfs dfsadmin -report 2>/dev/null) \
        && echo "$report" | grep -q 'Live datanodes.*[1-9]'; then
    pass live_datanode
else
    fail live_datanode
fi

# 5. mapreduce_smoke — pi 2 5 proves end-to-end MapReduce works; combiner is sound (sum is associative+commutative)
echo "  Running MapReduce smoke test (pi 2 5) — up to 180s..."
smoke_exit=0
timeout 180 docker compose exec -T resourcemanager bash -c \
    'yarn jar $(ls /opt/hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar | head -1) pi 2 5' \
    2>&1 | tee /tmp/nasa_smoke_pi.txt || smoke_exit=$?
if [ "$smoke_exit" -eq 0 ] && grep -q 'Estimated value of Pi' /tmp/nasa_smoke_pi.txt; then
    grep 'Estimated value of Pi' /tmp/nasa_smoke_pi.txt
    docker compose exec -T resourcemanager hdfs dfs -rm -r -f '/user/root/QuasiMonteCarlo_*' 2>/dev/null || true
    pass mapreduce_smoke
else
    fail mapreduce_smoke
fi

echo ""
echo "Results: $((5 - FAILURES)) passed, $FAILURES failed."
[ "$FAILURES" -eq 0 ]
