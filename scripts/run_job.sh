#!/usr/bin/env bash
set -euo pipefail

JOB_NAME=${1:?usage: run_job.sh <job_name>}
NUM_REDUCERS=${2:-3}

JAR=$(docker compose exec -T resourcemanager bash -c \
    'ls /opt/hadoop/share/hadoop/tools/lib/hadoop-streaming-*.jar | head -1')

# Clean previous output so the job does not fail on existing directory
docker compose exec -T resourcemanager hdfs dfs -rm -r -f "/user/root/output/$JOB_NAME" || true

# Docker Desktop WSL2 bind mounts can appear empty inside the container.
# Copy the scripts directly into the container so -files can reference them.
docker compose exec -T resourcemanager bash -c "mkdir -p /tmp/jobs/$JOB_NAME"
docker cp "jobs/$JOB_NAME/." "nasa-resourcemanager:/tmp/jobs/$JOB_NAME/"

# Build -files list from the copied scripts
FILES=$(docker compose exec -T resourcemanager bash -c \
    "ls /tmp/jobs/$JOB_NAME/*.py" | tr '\n' ',' | sed 's/,$//')

# Detect optional combiner
COMBINER_ARGS=""
if docker compose exec -T resourcemanager bash -c \
        "test -f /tmp/jobs/$JOB_NAME/combiner.py" 2>/dev/null; then
    COMBINER_ARGS="-combiner 'python3 combiner.py'"
fi

echo "Submitting job: $JOB_NAME"
docker compose exec -T resourcemanager bash -c "
    mapred streaming \
        -files '$FILES' \
        -mapper 'python3 mapper.py' \
        $COMBINER_ARGS \
        -reducer 'python3 reducer.py' \
        -input /user/root/input/NASA_access_log_Jul95 \
        -output /user/root/output/$JOB_NAME \
        -numReduceTasks $NUM_REDUCERS
"

echo "Merging output..."
docker compose exec -T resourcemanager \
    hdfs dfs -getmerge "/user/root/output/$JOB_NAME" "/data/output/$JOB_NAME.raw.txt"

# regenerate JSON for dashboard if script exists
if [ -f scripts/results_to_json.sh ]; then
    bash scripts/results_to_json.sh 2>/dev/null || true
fi

echo "Done: data/output/$JOB_NAME.raw.txt"
