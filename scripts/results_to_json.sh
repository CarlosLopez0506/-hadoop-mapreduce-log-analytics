#!/usr/bin/env bash
set -euo pipefail
OUT=data/output

mkdir -p dashboard/api/results

# top_resources: "path\tcount" → [{path, count}]
python3 -c "
import sys, json
rows = []
for line in open('$OUT/top_resources.txt'):
    parts = line.strip().split('\t')
    if len(parts) == 2:
        rows.append({'path': parts[0], 'count': int(parts[1])})
print(json.dumps(rows))
" > dashboard/api/results/top_resources.json

# status_bytes: "status\tcount\tbytes" → [{status, count, bytes}]
python3 -c "
import sys, json
rows = []
for line in open('$OUT/status_bytes.txt'):
    parts = line.strip().split('\t')
    if len(parts) == 3:
        rows.append({'status': parts[0], 'count': int(parts[1]), 'bytes': int(parts[2])})
print(json.dumps(rows))
" > dashboard/api/results/status_bytes.json

# hourly_traffic: "HH\tcount" → [{hour, count}]
python3 -c "
import sys, json
rows = []
for line in open('$OUT/hourly_traffic.txt'):
    parts = line.strip().split('\t')
    if len(parts) == 2:
        rows.append({'hour': int(parts[0]), 'count': int(parts[1])})
print(json.dumps(rows))
" > dashboard/api/results/hourly_traffic.json

echo "JSON results written to dashboard/api/results/"
