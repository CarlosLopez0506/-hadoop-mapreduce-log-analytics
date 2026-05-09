#!/usr/bin/env bash
set -euo pipefail

JOB_NAME=${1:?usage: run_job.sh <job_name>}

JAR=$(docker compose exec -T resourcemanager bash -c \
    'ls /opt/hadoop/share/hadoop/tools/lib/hadoop-streaming-*.jar | head -1')

# Clean previous output so the job does not fail on existing directory
docker compose exec -T resourcemanager hdfs dfs -rm -r -f "/user/root/output/$JOB_NAME" || true

# Build -files list from every .py in the job directory
FILES=$(docker compose exec -T resourcemanager bash -c \
    "ls /opt/jobs/$JOB_NAME/*.py" | tr '\n' ',' | sed 's/,$//')

# Detect optional combiner
COMBINER_ARGS=""
if docker compose exec -T resourcemanager bash -c \
        "test -f /opt/jobs/$JOB_NAME/combiner.py" 2>/dev/null; then
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
        -numReduceTasks 1
"

echo "Merging output..."
docker compose exec -T resourcemanager \
    hdfs dfs -getmerge "/user/root/output/$JOB_NAME" "/data/output/$JOB_NAME.raw.txt"

echo "Done: data/output/$JOB_NAME.raw.txt"
