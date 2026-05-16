# NASA HTTP Log — MapReduce Demo

Hadoop 3.4.1 · Python 3 · Docker Compose

## Quickstart

```bash
make up      # build image, start 5 containers, wait until healthy
make demo    # download dataset, load to HDFS, run both jobs, print results
make down    # stop and remove containers
```

## Run on AWS EC2 (Ansible)

Deploys the full cluster on an EC2 m5.xlarge via SSM — no SSH required.

**One-time local setup:**

```bash
pip install boto3 botocore ansible
ansible-galaxy collection install -r ansible/requirements.yml
# Install Session Manager Plugin:
# https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
```

**Every session:**

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1
export REPO_URL=https://github.com/CarlosLopez0506/-hadoop-mapreduce-log-analytics

ansible-playbook ansible/revive.yml
```

This single command: launches the EC2 instance, clones the repo, builds the Docker image, starts the 7-container Hadoop cluster, downloads the dataset, loads it into HDFS, runs all 3 MapReduce jobs, and deploys the dashboard.

**When done:**

```bash
ansible-playbook ansible/revive.yml --tags teardown
```

Cost: ~$0.13 for a full run (~40 min at $0.192/hr for m5.xlarge).

## What this is

Two MapReduce streaming jobs over the NASA Kennedy Space Center HTTP access log for July 1995 (1.9 M requests, 205 MB uncompressed). Job 1 counts hits per URL and uses a combiner to demonstrate the map → combine → shuffle → reduce flow. Job 2 groups requests by HTTP status code and sums bytes transferred per group. The entire pipeline runs inside five Docker containers and collapses to one command: `make demo`.

## Architecture

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

Full per-record trace: [docs/architecture.md](docs/architecture.md)

## Anatomy of a job

One input line from the log:

```
133.43.96.45 - - [01/Jul/1995:00:00:23 -0400] "GET /images/NASA-logosmall.gif HTTP/1.0" 200 786
```

**Mapper** (`jobs/top_resources/mapper.py`) emits one key-value pair:

```
/images/NASA-logosmall.gif	1
```

**Combiner** sums counts locally within each split before the shuffle — reducing ~1.9 M intermediate records to ~27 K across the wire.

**Reducer** (`jobs/top_resources/reducer.py`) sums all partial counts and emits the final total:

```
/images/NASA-logosmall.gif	111330
```

**Streaming command** (executed inside `resourcemanager` by `scripts/run_job.sh`):

```bash
mapred streaming \
    -files /opt/jobs/top_resources/mapper.py,combiner.py,reducer.py \
    -mapper  "python3 mapper.py"   \
    -combiner "python3 combiner.py" \
    -reducer  "python3 reducer.py"  \
    -input  /user/root/input/NASA_access_log_Jul95 \
    -output /user/root/output/top_resources \
    -numReduceTasks 1
```

**Data locations at each step:**

| Step | Location |
|---|---|
| Raw file on host | `./data/NASA_access_log_Jul95` |
| Visible inside namenode | `/data/NASA_access_log_Jul95` (bind mount) |
| In HDFS | `/user/root/input/NASA_access_log_Jul95` |
| Job output in HDFS | `/user/root/output/top_resources/part-00000` |
| Merged to host | `./data/output/top_resources.raw.txt` |
| Top-20 trimmed | `./data/output/top_resources.txt` |

## Web UIs

| Port | Service | URL |
|---|---|---|
| 9870 | NameNode | http://localhost:9870 |
| 9864 | DataNode | http://localhost:9864 |
| 8088 | ResourceManager (YARN) | http://localhost:8088 |
| 8042 | NodeManager | http://localhost:8042 |
| 19888 | Job History Server | http://localhost:19888 |

## Metrics

Full output and counter details: [docs/sample_output.md](docs/sample_output.md)

**Job 1 — top_resources** (wall-clock ~27 s)

| Stage | Records |
|---|---|
| Map input | 1,891,715 |
| Combine input | 1,889,757 |
| Combine output | 26,793 |
| Reduce input | 26,793 |
| Reduce output (unique paths) | 21,104 |
| nasa.malformed_line | 2 |

Bytes shuffled: 1,052,911 (vs 64,593,229 pre-combine — 98% reduction).

**Job 2 — status_bytes** (wall-clock ~34 s)

| Stage | Records |
|---|---|
| Map input | 1,891,715 |
| Combine input | 0 (no combiner) |
| Reduce input | 1,891,713 |
| Reduce output (distinct statuses) | 8 |
| nasa.malformed_line | 2 |

## Troubleshooting

**Port conflict on 8088 or 9870**

Another service (Spark, Airflow, another Hadoop) may be using these ports. Change the host-side port in `docker-compose.yml` (e.g. `18088:8088`) and update the matching `hadoop.env` variable if needed. The container-internal ports do not change.

**Slow first start — datanode not registering**

The `make up` target polls every 5 s for up to 180 s until all five containers report `healthy`. If it times out, run `docker compose logs datanode` to check whether the datanode is still waiting on the namenode's RPC port. Usually a second `make up` (idempotent) resolves it.

**YARN container OOM**

`hadoop.env` already sets `yarn.nodemanager.pmem-check-enabled=false` and `yarn.nodemanager.vmem-check-enabled=false`. If map tasks are still killed, the host itself may be low on memory. Close other applications and retry.

**WSL2 disk pressure**

The Docker image is ~1.5 GB and the uncompressed dataset is 205 MB. Reserve at least 3 GB of free disk before running `make demo`. `make clean` removes all job outputs, the downloaded dataset, and Docker volumes.

## Reproducibility

```bash
make clean   # remove outputs, dataset, and Docker volumes
make demo    # full pipeline from scratch (~3 min on a laptop)
```

The dataset SHA-256 is hardcoded in `scripts/download_dataset.sh`; the download step verifies it on every run. No internet access is needed after the first download (the `.gz` is kept as a cache in `./data/`).

See [docs/PLAN.md](docs/PLAN.md) for the full design rationale and closed technical decisions.
