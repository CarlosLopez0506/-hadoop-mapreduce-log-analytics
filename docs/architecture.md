# Architecture

## Cluster diagram

```
                            host (WSL2 / Linux)
                            +-------------------------+
                            |  ./data/                |   bind mount
                            |    NASA_access_log_*    | <----------------+
                            |    output/              |                  |
                            |  ./jobs/  (mappers)     | <----------+     |
                            +-------------------------+            |     |
                                                                   |     |
docker-compose network "hadoop_net"                                |     |
+-----------------+  +-----------------+  +-----------------+      |     |
| namenode        |  | datanode        |  | resourcemanager |  ----+     |
|  hdfs namenode  |  |  hdfs datanode  |  |  yarn rm + job  |  /opt/jobs |
|  :9870 (web UI) |  |  :9864 (web UI) |  |  submission     |  /data     |
+--------+--------+  +--------+--------+  |  :8088 (web UI) |  ----------+
         |                    |           +--------+--------+
         |   HDFS RPC :8020   |                    |
         +--------------------+                    |
                                                   |
                            +-----------------+    |
                            | nodemanager     | <--+
                            |  yarn nm        |
                            |  :8042 (web UI) |
                            +-----------------+

                            +-----------------+
                            | historyserver   |
                            |  mapred hs      |
                            |  :19888 (UI)    |
                            +-----------------+
```

Five containers, all built from a single local `Dockerfile` extending `apache/hadoop:3.4.1` with `python3` and `curl` added. Configuration is injected via `hadoop.env` using the image's env→XML translator (`CORE-SITE.XML_*`, `HDFS-SITE.XML_*`, etc.).

---

## Per-record trace (Job 1: top_resources)

One input line from the NASA log:

```
133.43.96.45 - - [01/Jul/1995:00:00:23 -0400] "GET /images/NASA-logosmall.gif HTTP/1.0" 200 786
```

### Step 1 — Host filesystem

The file `./data/NASA_access_log_Jul95` lives on the Docker host (WSL2). The `./data` directory is bind-mounted into the `namenode` container at `/data`.

### Step 2 — HDFS ingest (`make load`)

Inside the `namenode` container:

```
hdfs dfs -put /data/NASA_access_log_Jul95 /user/root/input/
```

HDFS splits the 205 MB file into 2 blocks (default 128 MB block size) and replicates each block once (replication factor = 1). Both blocks land on the single `datanode` container.

### Step 3 — Job submission (`make job-top`)

`run_job.sh` execs inside `resourcemanager`:

```
mapred streaming \
    -files /opt/jobs/top_resources/mapper.py,...  \
    -mapper  "python3 mapper.py"  \
    -combiner "python3 combiner.py" \
    -reducer  "python3 reducer.py"  \
    -input  /user/root/input/NASA_access_log_Jul95 \
    -output /user/root/output/top_resources \
    -numReduceTasks 1
```

YARN launches 2 map tasks (one per HDFS split) on the `nodemanager`.

### Step 4 — Map phase

Each map task pipes its assigned input split through `mapper.py` via stdin:

```python
# mapper.py receives the line above
m = LINE_RE.match(line)
# m.group(4) == "/images/NASA-logosmall.gif"
print("/images/NASA-logosmall.gif\t1")   # → stdout → Hadoop framework
```

### Step 5 — Combine phase (local aggregation)

Before the shuffle, `combiner.py` runs on each mapper's sorted output. All occurrences of the same path within one split are summed locally:

```
/images/NASA-logosmall.gif  1          # raw mapper output (repeated N times)
/images/NASA-logosmall.gif  1
...
──────────────────────────────────────
/images/NASA-logosmall.gif  47231      # combiner output (one entry per split)
```

This reduces ~1.9 M intermediate records to ~27 K before any network transfer.

### Step 6 — Shuffle & sort

The framework partitions combiner output by key, transfers it over `hadoop_net` from the nodemanager to the reducer slot, and merges+sorts all entries by key. The single reducer receives all counts for every URL.

### Step 7 — Reduce phase

`reducer.py` sums all partial counts for each key:

```
/images/NASA-logosmall.gif  47231   # from split 0
/images/NASA-logosmall.gif  64099   # from split 1
──────────────────────────────────────────────────
/images/NASA-logosmall.gif  111330  # reducer output → HDFS
```

### Step 8 — HDFS output

The reducer writes `path\tcount` lines to `/user/root/output/top_resources/part-00000` in HDFS on the `datanode`.

### Step 9 — Materialization (`hdfs dfs -getmerge`)

`run_job.sh` merges the single part file to the bind-mounted `/data/output/top_resources.raw.txt`, which appears immediately on the host as `./data/output/top_resources.raw.txt`.

### Step 10 — Top-20 trim

```bash
sort -k2 -n -r data/output/top_resources.raw.txt | head -20 > data/output/top_resources.txt
```

Sorting and trimming happen on the host (no Hadoop), keeping the reducer output canonical and inspectable in full.
