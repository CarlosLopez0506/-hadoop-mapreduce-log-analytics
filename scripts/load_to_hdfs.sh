#!/usr/bin/env bash
set -euo pipefail

HDFS_INPUT=/user/root/input
LOCAL_FILE=/data/NASA_access_log_Jul95
HDFS_FILE="$HDFS_INPUT/NASA_access_log_Jul95"

# Verify cluster is up
if ! docker compose ps namenode --status running 2>/dev/null | grep -q namenode; then
    echo "Cluster is not running. Run 'make up' first." >&2
    exit 1
fi

docker compose exec -T namenode hdfs dfs -mkdir -p "$HDFS_INPUT"

if docker compose exec -T namenode hdfs dfs -test -e "$HDFS_FILE" 2>/dev/null; then
    echo "Already loaded, skipping."
    exit 0
fi

echo "Uploading $LOCAL_FILE to HDFS $HDFS_FILE ..."
docker compose exec -T namenode hdfs dfs -Ddfs.replication=2 -put "$LOCAL_FILE" "$HDFS_INPUT/"

docker compose exec -T namenode hdfs dfs -ls -h "$HDFS_INPUT/"
