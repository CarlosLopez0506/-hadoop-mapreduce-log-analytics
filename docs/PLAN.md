# docs/PLAN.md — MapReduce NASA Access Log Demo

## 1. Context

Demo for the final presentation of "Aprendizaje Automático para Grandes Volúmenes de Datos" (Universidad Panamericana, 15-min live class). The repo must produce a reproducible, lint-clean Hadoop MapReduce demo on Docker that runs **two** non-trivial jobs over the NASA Kennedy Space Center HTTP access log of July 1995 (~1.9M requests, 205 MB uncompressed):

1. **Top requested resources** — counts hits per URL with a combiner (pedagogically demonstrates map → combine → shuffle → reduce).
2. **Status code distribution + bytes transferred** — groups by HTTP status and reduces composite values (count + total bytes).

The demo collapses to one command: `make demo`. The audience is technical (senior CS students + a PhD professor); the bar is "feels like real data engineering, not the tutorial word-count".

This document is the contract between the planning session (Opus 4.7) and the Sonnet 4.6 sessions that execute each milestone in isolation. **It is committed to the repo before M1 begins.** Sonnet sessions read this file end-to-end before touching anything.

## 2. Target architecture

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

**Services**: 5 containers, all derived from a thin local `Dockerfile` that extends `apache/hadoop:3.4.1` and adds `python3` + `curl`. Each container runs one Hadoop role.

**Exposed ports** (host → container, all configurable via `hadoop.env`):
- `9870` NameNode HTTP UI
- `9864` DataNode HTTP UI
- `8088` ResourceManager HTTP UI
- `8042` NodeManager HTTP UI
- `19888` JobHistory HTTP UI
- `8020` NameNode RPC (internal-only on the compose network; not exposed to host)

**End-to-end job flow**:
1. `scripts/download_dataset.sh` fetches `NASA_access_log_Jul95.gz` to `./data/`, validates SHA-256, gunzips it.
2. `scripts/load_to_hdfs.sh` execs `hdfs dfs -put` inside the `namenode` container against the bind-mounted `/data` to copy the file to `/user/root/input/`.
3. `scripts/run_job.sh <job_name>` execs `mapred streaming` inside the `resourcemanager` container with `-files` shipping `mapper.py`, optional `combiner.py`, `reducer.py` to workers.
4. After completion, `hdfs dfs -getmerge` writes a single output file to `/data/output/<job>.txt` on the host (visible immediately via the bind mount).
5. `make results` `cat`s both output files for the audience.

## 3. Technical decisions (closed — not to be re-litigated by milestones)

| Decision | Choice | Justification |
|---|---|---|
| Hadoop base image | `apache/hadoop:3.4.1` | Official, multi-arch, 3.4 line is documented through 2025; `3.3.6` is no longer listed on Docker Hub. |
| Local image build | `Dockerfile` extending base | Adds `python3` and `curl` so streaming + healthchecks are reliable regardless of base-image drift. |
| Python in containers | `python3` from distro repo (whatever ships with the Hadoop runner base, currently 3.10/3.11) | The mappers/reducers use only stdlib (`re`, `sys`, `collections`); minor-version drift is irrelevant. |
| Cluster topology | 5 separate containers (NN, DN, RM, NM, HS) | The user explicitly forbade a monolithic image; pedagogically clearer. |
| Service start | `command: hdfs namenode` etc. (matches the upstream `apache/hadoop` compose example) | Standard upstream pattern. |
| Configuration | `hadoop.env` env_file + the image's built-in env→XML translator (`CORE-SITE.XML_*`, `HDFS-SITE.XML_*`, `MAPRED-SITE.XML_*`, `YARN-SITE.XML_*`) | No need to ship `core-site.xml` etc. as files. |
| HDFS replication | `dfs.replication=1` | Single DataNode in pseudo-distributed mode. |
| HDFS permissions | `dfs.permissions.enabled=false` | Simplifies running jobs as root inside the RM container. |
| Healthcheck | `curl -fsS http://localhost:<ui-port>/ \|\| exit 1` per service, `interval: 10s`, `timeout: 5s`, `retries: 12`, `start_period: 30s` | All services expose web UIs that return 200 once ready; uniform check is simple. |
| `depends_on` | Use `condition: service_healthy` for the chain NN → DN → RM → NM/HS | Compose v2 supports this; ensures `make up` blocks until ready. |
| Dataset transfer | Bind-mount `./data` → `/data` in `namenode`; copy via `hdfs dfs -put` from inside the container | One source of truth for the file; no duplicated state. |
| Output materialization | Bind-mount `./data/output` → `/data/output`; `hdfs dfs -getmerge` writes a single file there | Audience can `cat ./data/output/top_resources.txt` immediately. |
| Streaming jar discovery | `ls /opt/hadoop/share/hadoop/tools/lib/hadoop-streaming-*.jar` inside the RM container | Future-proof against Hadoop minor version changes. |
| Reducer count | 1 for both jobs | Dataset is small; deterministic ordering simplifies verification. |
| Job submission user | `root` (image default) | Avoid YARN user-mapping rabbit hole for a 15-min demo. |
| Dataset primary URL | `https://raw.githubusercontent.com/greymd/NASA-HTTP/main/NASA_access_log_Jul95.gz` | HTTPS, GitHub-backed, mirror of the LBL FTP; FTP infrastructure is increasingly fragile in 2026. |
| Dataset fallback URL | `ftp://ita.ee.lbl.gov/traces/NASA_access_log_Jul95.gz` | Original source, still listed on the LBL contributors page. |
| Checksum | SHA-256 pinned at first successful run | LBL does not publish official checksums; we compute once from the GitHub mirror, hardcode in the script, and verify on every subsequent run. |
| Malformed-line handling | Mappers emit `reporter:counter:nasa,malformed_line,1` to stderr and `continue` | Streaming counters are visible in the YARN UI and JobHistory. |
| `bytes == "-"` handling | Treat as `0` in the status_bytes mapper | Matches the original CLF semantics ("no body sent"). |
| Combiner scope | Job 1 only (`top_resources`) — simple commutative+associative `sum` | Job 2 emits composite values; the user spec asks for the combiner explicitly only for job 1. |

## 4. Milestones

Each milestone is one Sonnet 4.6 session (with the exception of those grouped in section 7 where noted). Each ends with a `git commit` whose subject is `milestone N: <short title>`.

---

### Milestone 1 — Repo skeleton + Makefile scaffold

- **Objetivo**: empty but well-organized repo, with a `Makefile` whose `help` lists all targets and whose targets are stubs that print `TODO: <name>` and exit 0. **`docs/PLAN.md` already exists in the repo before this milestone runs (created by the Opus planning session); M1 does NOT touch it.**
- **Archivos a crear**:
  - `Makefile`
  - `.gitignore`
  - `data/.gitkeep`
  - `data/output/.gitkeep`
  - `jobs/top_resources/.gitkeep`
  - `jobs/status_bytes/.gitkeep`
  - `scripts/.gitkeep`
- **Tamaño estimado**: ~70 lines, S.
- **Pre-requisitos**: `docs/PLAN.md` is committed to the repo (done by Opus before this milestone).
- **Especificación detallada**:
  - `Makefile` targets, all stubs except `help` and `clean`:
    `help` (default), `up`, `down`, `verify`, `download`, `load`, `job-top`, `job-status`, `results`, `demo`, `clean`, `test`.
  - `help` prints a two-column table: target name + one-line description. Implement using a `## description` convention scraped via `awk` (standard pattern).
  - `clean` removes `data/output/*` (preserving `.gitkeep`), `data/NASA_access_log_Jul95*`, and runs `docker compose down -v --remove-orphans 2>/dev/null || true`.
  - `.PHONY` declared for every target.
  - `SHELL := /bin/bash` and `.ONESHELL:` enabled (multi-line bash blocks are needed in later milestones).
  - `.gitignore`:
    ```
    # Dataset
    data/*
    !data/.gitkeep
    !data/output/
    # Job outputs
    data/output/*
    !data/output/.gitkeep
    # Python
    __pycache__/
    *.pyc
    # OS
    .DS_Store
    ```
    (The two-rule pattern is intentional: the first block excludes the dataset; the second explicitly handles `data/output/` so job-result files are gitignored without losing the directory entry.)
  - Initial commit. Clean working tree before/after.
- **Comando de verificación**: `make help` — prints all 12 targets with descriptions, exit 0.
- **Criterio de done**:
  - [ ] `make help` lists every target with a description.
  - [ ] `make clean` runs without error on a fresh checkout.
  - [ ] `git status` is clean.
  - [ ] `find . -name '*.py'` returns nothing (no production code yet).
  - [ ] `git ls-files docs/PLAN.md` returns the file (was committed by Opus before this milestone).

---

### Milestone 2 — Cluster spec (Dockerfile, docker-compose.yml, hadoop.env, verify_cluster.sh)

- **Objetivo**: `make up && make verify` brings 5 healthy containers, confirms HDFS reports a live DataNode, **and confirms a real MapReduce job (`pi 2 5`) completes end-to-end**.
- **Archivos a crear**:
  - `Dockerfile`
  - `docker-compose.yml`
  - `hadoop.env`
  - `scripts/verify_cluster.sh`
  - `Makefile` (edit: implement `up`, `down`, `verify`)
- **Tamaño estimado**: ~170 lines (compose ~80, env ~30, Dockerfile ~10, verify script ~50), M.
- **Pre-requisitos**: M1.
- **Especificación detallada**:
  - **Dockerfile**:
    ```dockerfile
    FROM apache/hadoop:3.4.1
    USER root
    RUN apt-get update && apt-get install -y --no-install-recommends python3 curl ca-certificates \
        && rm -rf /var/lib/apt/lists/*
    USER hadoop
    ```
    Image name in compose: `mapreduce-nasa:3.4.1`.
  - **docker-compose.yml** (Compose v2 schema, no `version:` key — deprecated):
    Services: `namenode`, `datanode`, `resourcemanager`, `nodemanager`, `historyserver`. All use `build: .` (so the image is built once and reused via `image: mapreduce-nasa:3.4.1`). All reference `env_file: ./hadoop.env`. All on a single user-defined network `hadoop_net`.
    - `namenode`: command `["hdfs", "namenode"]`. Env extras: `ENSURE_NAMENODE_DIR=/tmp/hadoop-root/dfs/name`. Ports: `9870:9870`. Volumes: `./data:/data`. Healthcheck on `:9870`.
    - `datanode`: command `["hdfs", "datanode"]`. Ports: `9864:9864`. `depends_on: namenode (service_healthy)`. Healthcheck on `:9864`.
    - `resourcemanager`: command `["yarn", "resourcemanager"]`. Ports: `8088:8088`. Volumes: `./data:/data`, `./jobs:/opt/jobs:ro`. `depends_on: datanode (service_healthy)`. Healthcheck on `:8088`.
    - `nodemanager`: command `["yarn", "nodemanager"]`. Ports: `8042:8042`. `depends_on: resourcemanager (service_healthy)`. Healthcheck on `:8042`.
    - `historyserver`: command `["mapred", "historyserver"]`. Ports: `19888:19888`. `depends_on: resourcemanager (service_healthy)`. Healthcheck on `:19888`.
    - Restart policy: `unless-stopped`. Container names: `nasa-<service>` for predictable `docker compose exec` calls.
  - **hadoop.env**:
    ```
    CORE-SITE.XML_fs.defaultFS=hdfs://namenode:8020
    CORE-SITE.XML_hadoop.http.staticuser.user=root
    HDFS-SITE.XML_dfs.replication=1
    HDFS-SITE.XML_dfs.permissions.enabled=false
    HDFS-SITE.XML_dfs.namenode.rpc-bind-host=0.0.0.0
    HDFS-SITE.XML_dfs.namenode.servicerpc-bind-host=0.0.0.0
    HDFS-SITE.XML_dfs.namenode.http-bind-host=0.0.0.0
    HDFS-SITE.XML_dfs.datanode.use.datanode.hostname=true
    MAPRED-SITE.XML_mapreduce.framework.name=yarn
    MAPRED-SITE.XML_yarn.app.mapreduce.am.env=HADOOP_MAPRED_HOME=/opt/hadoop
    MAPRED-SITE.XML_mapreduce.map.env=HADOOP_MAPRED_HOME=/opt/hadoop
    MAPRED-SITE.XML_mapreduce.reduce.env=HADOOP_MAPRED_HOME=/opt/hadoop
    YARN-SITE.XML_yarn.resourcemanager.hostname=resourcemanager
    YARN-SITE.XML_yarn.nodemanager.pmem-check-enabled=false
    YARN-SITE.XML_yarn.nodemanager.vmem-check-enabled=false
    YARN-SITE.XML_yarn.nodemanager.aux-services=mapreduce_shuffle
    ```
  - **scripts/verify_cluster.sh**: bash, `set -euo pipefail`. Prints `[PASS] <name>` or `[FAIL] <name>` per check, aggregates exit code (any FAIL → exit 1). Checks:
    1. **container_health**: all 5 containers report state `running` and `Health: healthy` via `docker inspect`.
    2. **namenode_ui**: `curl -fsS http://localhost:9870/dfshealth.html` returns 200.
    3. **resourcemanager_ui**: `curl -fsS http://localhost:8088/cluster` returns 200.
    4. **live_datanode**: `docker compose exec -T namenode hdfs dfsadmin -report` shows ≥1 live DataNode.
    5. **mapreduce_smoke**: `docker compose exec -T resourcemanager bash -lc 'yarn jar $(ls /opt/hadoop/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar | head -1) pi 2 5'` exits 0 within 180 seconds. (The `pi` example with 2 maps × 5 samples is the canonical MapReduce smoke test; runs in <60s on a laptop and proves the cluster can actually execute a job.) After it completes, clean up its scratch output directory: `hdfs dfs -rm -r -f /user/root/QuasiMonteCarlo_*`.
  - **Makefile additions**:
    - `up`: `docker compose up -d --build` then poll `docker compose ps` until all healthy or 180s timeout.
    - `down`: `docker compose down`.
    - `verify`: `bash scripts/verify_cluster.sh`.
- **Comando de verificación**: `make up && make verify` — exit 0; `docker compose ps` shows 5 `(healthy)`; the last verify check prints the estimated π value (e.g. `Estimated value of Pi is 3.20000000000000000000`).
- **Criterio de done**:
  - [ ] `make up` returns control only when all containers are healthy.
  - [ ] `make verify` exits 0 with all five checks passing (note: five, not four — the `pi` smoke test is the fifth).
  - [ ] All 5 web UIs reachable on the documented host ports.
  - [ ] The `pi` example completes successfully and its output directory is cleaned up.
  - [ ] `make down` removes containers and the network.
  - [ ] No `:latest` tag anywhere; image is `mapreduce-nasa:3.4.1`.

---

### Milestone 3 — Dataset download with checksum

- **Objetivo**: `make download` produces `./data/NASA_access_log_Jul95` (uncompressed, ~205 MB), idempotently, with SHA-256 verification.
- **Archivos a crear/modificar**:
  - `scripts/download_dataset.sh`
  - `Makefile` (edit: implement `download`)
- **Tamaño estimado**: ~70 lines bash, S.
- **Pre-requisitos**: M1.
- **Especificación detallada**:
  - Bash, `set -euo pipefail`. Constants:
    - `DATA_DIR=./data`
    - `GZ_NAME=NASA_access_log_Jul95.gz`
    - `RAW_NAME=NASA_access_log_Jul95`
    - `PRIMARY_URL=https://raw.githubusercontent.com/greymd/NASA-HTTP/main/NASA_access_log_Jul95.gz`
    - `FALLBACK_URL=ftp://ita.ee.lbl.gov/traces/NASA_access_log_Jul95.gz`
    - `EXPECTED_SHA256` — set to the empty string in the initial implementation. **First-run bootstrap**: if the variable is empty, the script downloads, computes the hash, prints it with a banner instructing the engineer to paste it into the script, and exits 0. On the second run, the variable is non-empty and verification is enforced. The Sonnet executing this milestone runs the bootstrap once, captures the hash, edits the script with the captured value, runs the script again to confirm verification passes, then commits the populated value.
  - Logic:
    1. If `$DATA_DIR/$RAW_NAME` exists with size between 200_000_000 and 220_000_000 bytes → exit 0 (idempotent skip).
    2. If `$DATA_DIR/$GZ_NAME` does not exist → `curl -fL --retry 3 --retry-delay 5 -o "$DATA_DIR/$GZ_NAME" "$PRIMARY_URL"`; on failure try `$FALLBACK_URL`.
    3. Compute SHA-256 with `sha256sum`. If `EXPECTED_SHA256` is empty, print and exit 0. Otherwise compare; on mismatch delete the file and exit 1.
    4. `gunzip -k "$DATA_DIR/$GZ_NAME"` (keeps the .gz around for cache).
    5. Print final size with `wc -c` and line count with `wc -l`.
  - `Makefile.download` calls the script.
- **Comando de verificación**: `make download` exits 0 (after the two-run bootstrap); `wc -l ./data/NASA_access_log_Jul95` reports between 1_891_000 and 1_892_000 lines (canonical figure: 1,891,715).
- **Criterio de done**:
  - [ ] First run prints the SHA-256 hash and exits 0.
  - [ ] After hash is pasted into the script, second run validates and exits 0.
  - [ ] Both runs and the script edit are in a single commit.
  - [ ] `make download` is idempotent (running twice does not redownload).
  - [ ] On simulated network failure (offline), the fallback URL is attempted before failing.

---

### Milestone 4 — Load to HDFS

- **Objetivo**: `make load` puts the local file into `/user/root/input/NASA_access_log_Jul95` in HDFS, idempotently.
- **Archivos a crear/modificar**:
  - `scripts/load_to_hdfs.sh`
  - `Makefile` (edit: implement `load`)
- **Tamaño estimado**: ~40 lines bash, S.
- **Pre-requisitos**: M2 (cluster up), M3 (file present locally).
- **Especificación detallada**:
  - Bash, `set -euo pipefail`. Uses `docker compose exec -T namenode <cmd>` for all HDFS calls.
  - Logic:
    1. Verify the cluster is up: `docker compose ps namenode --status running` non-empty; if not, `echo "run 'make up' first"` and exit 1.
    2. `hdfs dfs -mkdir -p /user/root/input`.
    3. If `hdfs dfs -test -e /user/root/input/NASA_access_log_Jul95` succeeds → echo "already loaded, skipping" and exit 0.
    4. `hdfs dfs -put /data/NASA_access_log_Jul95 /user/root/input/`.
    5. Print `hdfs dfs -ls -h /user/root/input/` for confirmation.
  - `Makefile.load` calls the script.
- **Comando de verificación**: `make load` exits 0; `docker compose exec namenode hdfs dfs -ls -h /user/root/input/NASA_access_log_Jul95` reports a single 195+ MB file.
- **Criterio de done**:
  - [ ] File present in HDFS with expected size (~205 MB / 1× replication).
  - [ ] Re-running `make load` is a no-op.
  - [ ] If cluster is down, command fails with a useful message rather than a stack trace.

---

### Milestone 5 — Job 1: top_resources (mapper + combiner + reducer + run_job.sh)

- **Objetivo**: `make job-top` runs the streaming job, materializes `./data/output/top_resources.txt` with the 20 most-requested URLs (descending).
- **Archivos a crear/modificar**:
  - `jobs/top_resources/mapper.py`
  - `jobs/top_resources/combiner.py`
  - `jobs/top_resources/reducer.py`
  - `scripts/run_job.sh`
  - `Makefile` (edit: implement `job-top`)
- **Tamaño estimado**: ~150 lines total, M.
- **Pre-requisitos**: M2, M4.
- **Especificación detallada**:
  - **CLF parser** (shared shape across both mappers; do NOT factor into a shared module — Hadoop Streaming `-files` ships per-job files; copy the regex into each mapper deliberately):
    ```python
    LINE_RE = re.compile(
        r'^(\S+) \S+ \S+ \[([^\]]+)\] '
        r'"(?:(\S+) (\S+)(?: (\S+))?|[^"]*)" '
        r'(\d{3}|-) (\d+|-)$'
    )
    ```
    Groups: 1=host, 2=timestamp, 3=method (optional), 4=path (optional), 5=protocol (optional), 6=status, 7=bytes. Lines that do not match are malformed.
  - **mapper.py** (top_resources):
    - Reads stdin line-by-line (UTF-8 with `errors="replace"`; the dataset has Latin-1 stray bytes).
    - For each line: try `LINE_RE.match`. On miss: `print("reporter:counter:nasa,malformed_line,1", file=sys.stderr)` and continue.
    - On match without a path (request was not a valid HTTP request): emit `reporter:counter:nasa,unparsed_request,1` and continue.
    - Emit `path\t1` to stdout.
  - **combiner.py** (top_resources):
    - Streaming sum: read `key\tvalue`, accumulate while key is identical, flush on key change. Final flush at EOF.
    - Asserts input is sorted by key — Hadoop guarantees this for combiner input.
  - **reducer.py** (top_resources):
    - Same streaming-sum logic as the combiner.
    - Output: `path\tcount`.
    - The "top 20" trimming happens **outside** the reducer in the Makefile via `sort -k2 -n -r | head -20` — keeps the reducer canonical and lets students inspect the full output if they want.
  - **scripts/run_job.sh** (generic):
    - Args: `$1=job_name`.
    - Logic:
      1. `JAR=$(docker compose exec -T resourcemanager bash -lc 'ls /opt/hadoop/share/hadoop/tools/lib/hadoop-streaming-*.jar | head -1')`
      2. `docker compose exec -T resourcemanager hdfs dfs -rm -r -f /user/root/output/$1 || true`
      3. Build `-files` argument by listing every `.py` in `/opt/jobs/$1/`.
      4. Detect combiner: if `combiner.py` exists in the job dir, append `-combiner "python3 combiner.py"`.
      5. Run:
         ```
         docker compose exec -T resourcemanager mapred streaming \
             -files <files> \
             -mapper "python3 mapper.py" \
             [-combiner "python3 combiner.py"] \
             -reducer "python3 reducer.py" \
             -input /user/root/input/NASA_access_log_Jul95 \
             -output /user/root/output/$1 \
             -numReduceTasks 1
         ```
      6. After success: `hdfs dfs -getmerge /user/root/output/$1 /data/output/$1.raw.txt`.
  - **Makefile job-top**:
    ```
    job-top: ## Run Job 1 (top resources)
    	bash scripts/run_job.sh top_resources
    	sort -k2 -n -r data/output/top_resources.raw.txt | head -20 > data/output/top_resources.txt
    ```
- **Comando de verificación**: `make job-top` — exits 0; `head -3 data/output/top_resources.txt` shows lines with paths, the top entry is one of `/images/NASA-logosmall.gif`, `/images/KSC-logosmall.gif`, `/images/MOSAIC-logosmall.gif`, or `/images/USA-logosmall.gif` (these dominate the dataset).
- **Criterio de done**:
  - [ ] Output file has exactly 20 lines, sorted descending by count.
  - [ ] Combiner is wired (verified by checking JobHistory web UI: "Combine input records" > 0).
  - [ ] Counter `nasa.malformed_line` is reported in the job summary (smoke evidence the parser is exercised, not silently returning).
  - [ ] Job runs in under 10 minutes; **record the actual wall-clock in `docs/sample_output.md` (this is observation, not a pass/fail condition)**.

---

### Milestone 6 — Job 2: status_bytes (mapper + reducer)

- **Objetivo**: `make job-status` materializes `./data/output/status_bytes.txt` with one row per HTTP status: `<status>\t<count>\t<total_bytes>`.
- **Archivos a crear/modificar**:
  - `jobs/status_bytes/mapper.py`
  - `jobs/status_bytes/reducer.py`
  - `Makefile` (edit: implement `job-status`)
- **Tamaño estimado**: ~80 lines total, S-M.
- **Pre-requisitos**: M5 (`run_job.sh` exists and is parameterized).
- **Especificación detallada**:
  - **mapper.py** (status_bytes):
    - Same `LINE_RE` as job 1.
    - On match, parse `bytes`: `int(bytes_field) if bytes_field != "-" else 0`.
    - Emit `status\t1\t<bytes>` (3 fields; reducer parses).
    - Same malformed-line counter.
  - **reducer.py** (status_bytes):
    - Streaming aggregate by status: maintain `current_key`, `count`, `bytes_sum`.
    - On key change or EOF: emit `current_key\t<count>\t<bytes_sum>`.
  - **Makefile**:
    ```
    job-status: ## Run Job 2 (status + bytes)
    	bash scripts/run_job.sh status_bytes
    	sort -k1 -n data/output/status_bytes.raw.txt > data/output/status_bytes.txt
    ```
- **Comando de verificación**: `make job-status` — exits 0; `cat data/output/status_bytes.txt` shows status `200` first (or numeric-sort-first row equivalent) with count > 1_700_000.
- **Criterio de done**:
  - [ ] Output has one row per distinct HTTP status (expect 200, 302, 304, 400, 403, 404, 500, 501).
  - [ ] Total count across rows matches the count in Job 1 within the malformed-line tolerance.
  - [ ] Bytes column for status 304 is exactly 0 (304 = Not Modified, no body).
  - [ ] No combiner used (verified: JobHistory shows zero combiner activity).

---

### Milestone 7 — `make demo` end-to-end + sample_output.md + architecture.md

- **Objetivo**: a single command runs the whole pipeline; capture the result for the slides.
- **Archivos a crear/modificar**:
  - `Makefile` (edit: implement `results`, `demo`)
  - `docs/sample_output.md`
  - `docs/architecture.md`
- **Tamaño estimado**: ~100 lines code + markdown, M.
- **Pre-requisitos**: M2–M6.
- **Especificación detallada**:
  - **Makefile.results**: prints (a) the top-20 table from job 1, (b) the status_bytes table from job 2, (c) timing & counter stats parsed from a saved YARN application report.
  - **Makefile.demo**: chain `up → verify → download → load → job-top → job-status → results`. Keep cluster running at the end so the audience can inspect the YARN UI; teardown is on the user.
  - **docs/sample_output.md**: paste real output from a real run plus the four most informative counters (Map input records, Reduce output records, Combine input records for job 1, malformed_line) AND the wall-clock numbers for both jobs (the time observation deferred from M5/M6).
  - **docs/architecture.md**: same diagram as in this PLAN, plus a step-by-step trace of one record through the pipeline (host → bind mount → namenode → HDFS block → split → mapper → combiner → shuffle → reducer → HDFS output → getmerge → host).
- **Comando de verificación**: `make demo` (cluster previously down; network present) — exits 0; `data/output/top_resources.txt` and `data/output/status_bytes.txt` both populated; `docs/sample_output.md` reflects the run with real timings.
- **Criterio de done**:
  - [ ] `make demo` runs unattended (no prompts, no manual hash pasting on a clean checkout — by this milestone the dataset hash is hardcoded from M3).
  - [ ] `docs/sample_output.md` contains real, not invented, numbers, including wall-clock per job.
  - [ ] `docs/architecture.md` includes the ASCII diagram and the per-record trace.

---

### Milestone 8 — README

- **Objetivo**: presentation-grade README. The reader can follow it in 30 seconds during the presentation introduction.
- **Archivos a crear/modificar**: `README.md`.
- **Tamaño estimado**: ~250 lines markdown, M.
- **Pre-requisitos**: M7 (sample numbers exist).
- **Especificación detallada**:
  - Sections (in this order, no others):
    1. **Quickstart** — three lines: `make up`, `make demo`, `make down`.
    2. **What this is** — three sentences max; mention dataset size, two jobs, combiner.
    3. **Architecture** — embed (or link to) the ASCII diagram from `docs/architecture.md`.
    4. **Anatomy of a job** — show one mapper line, one reducer line, the streaming command, and where the data lives at each step.
    5. **Web UIs** — table of host port → service → URL.
    6. **Metrics** — table copied from `sample_output.md`: records in/out per stage, bytes shuffled, wall-clock per job.
    7. **Troubleshooting** — port conflict on 8088/9870, slow first start (datanode registration), out-of-memory on YARN containers, WSL2 disk pressure.
    8. **Reproducibility** — `make clean && make demo` from a fresh checkout.
  - No emojis, no marketing language, no badges other than (optionally) "Hadoop 3.4.1" / "Python 3" plain text labels.
- **Comando de verificación**: `make help` and `make demo` referenced commands all exist as Make targets; `grep -c '^##' README.md` ≥ 8 (one per section).
- **Criterio de done**:
  - [ ] Every command mentioned in README.md exists as a Make target or a `scripts/*.sh` file.
  - [ ] No broken links between README.md, docs/architecture.md, docs/sample_output.md, docs/PLAN.md.
  - [ ] No emojis or `:latest` tags.
  - [ ] Lints clean with `markdownlint` if present (or visual review otherwise).

---

### Milestone 9 — Tests

- **Objetivo**: lock the parser/reducer behavior with stdlib unit tests.
- **Archivos a crear/modificar**:
  - `tests/test_mappers.py`
  - `Makefile` (edit: implement `test`)
- **Tamaño estimado**: ~120 lines python + small Makefile change, S-M.
- **Pre-requisitos**: M5, M6.
- **Especificación detallada**:
  - `tests/test_mappers.py` uses stdlib `unittest`, no pytest. Tests:
    - `test_top_resources_mapper_emits_path_for_valid_line`
    - `test_top_resources_mapper_skips_malformed_line`
    - `test_status_bytes_mapper_emits_zero_when_bytes_dash` (e.g. status 304 line)
    - `test_status_bytes_mapper_handles_post_with_path`
    - `test_reducer_streaming_sum_aggregates_correctly` (top_resources reducer)
    - `test_reducer_status_bytes_aggregates_three_fields`
  - Inputs are 6–10 hardcoded representative lines (real-world samples from the Jul95 dataset, including one 304 with `-` bytes, one malformed line, one Latin-1-byte line).
  - Mappers/reducers are imported directly from `jobs/.../mapper.py` etc. — that means the modules must be import-safe (no top-level execution beyond `if __name__ == "__main__"`). Update mappers/reducers in this milestone if needed.
  - `Makefile.test`:
    ```
    test: ## Run unit tests for mappers and reducers
    	cd tests && python3 -m unittest -v
    ```
- **Comando de verificación**: `make test` — exit 0.
- **Criterio de done**:
  - [ ] All 6 unit tests pass.
  - [ ] No mapper/reducer imports anything outside `re`, `sys`, `collections`.
  - [ ] Mappers/reducers are import-safe (entry point guarded by `if __name__ == "__main__"`).
  - [ ] Note: clean-room reproducibility (`make clean && make demo`) is validated **manually by Esteban** outside Sonnet sessions.

## 5. Conventions for future Sonnet sessions

Every Sonnet session **must** do, in order:

1. **Pre-flight**:
   - Run `git status`. If not clean → STOP. Ask the user before doing anything.
   - Run `git log --oneline -10` to see what milestones are done.
   - Read `docs/PLAN.md` end-to-end. Read the assigned milestone twice.
2. **Scope**:
   - Touch ONLY the files listed in "Archivos a crear/modificar" of the assigned milestone.
   - If you discover you need another file → STOP. Ask the user.
   - Do not refactor adjacent code "for cleanliness". The plan is the contract.
3. **Execution**:
   - Implement the spec as written. Do not invent extra targets, extra services, extra abstractions.
   - Comments only where a non-obvious "why" is needed (e.g., "combiner is sound here because sum is associative+commutative", "reducer relies on Hadoop's per-key sort guarantee").
4. **Verification**:
   - Run the milestone's "Comando de verificación".
   - Walk through "Criterio de done"; every box must check.
   - If any box fails → do NOT commit. Report the failing check, the command output, and the last known good state.
5. **Commit**:
   - One commit per milestone. Subject: `milestone N: <short title>`. Body: one sentence per non-trivial decision.
   - Report back: the commit SHA, the verification command output (last 20 lines), and the next milestone to run.

Forbidden across all sessions:
- Bumping image tags. The pinned tag is `apache/hadoop:3.4.1`.
- Adding Python dependencies. Stdlib only.
- Adding services to docker-compose. The cluster is 5 services.
- Using `:latest` anywhere.
- Writing emojis or marketing prose.

## 6. Risks and mitigations

| Risk | Probability | Mitigation |
|---|---|---|
| `apache/hadoop:3.4.1` env-to-XML translation drifts in detail | Low-Med | M2 includes `make verify`, which catches an unconfigured cluster on first boot. The `pi` smoke test in verify is the canary. If env keys don't apply, fall back to mounting `core-site.xml` + `hdfs-site.xml` files explicitly (Plan B documented in M2 troubleshooting). |
| Streaming jar path differs in 3.4.1 | Low | `run_job.sh` uses `ls /opt/hadoop/share/hadoop/tools/lib/hadoop-streaming-*.jar` (glob), not a hardcoded path. |
| Examples jar path differs in 3.4.1 | Low | Same `ls`+glob pattern in `verify_cluster.sh`. |
| Primary dataset URL (GitHub mirror) goes stale | Low | Fallback to LBL FTP. If both fail, document a third Kaggle mirror (`souhagaa/nasa-access-log-dataset-1995`) in README troubleshooting. |
| LBL FTP infrastructure removed entirely | Low | The GitHub mirror is the primary; FTP is just a fallback. |
| Port conflict on 8088/9870/19888 (common with Spark / Airflow on the same host) | Med | All host ports are parameterized via `hadoop.env`; troubleshooting section in README explains how to remap. |
| WSL2 / Docker Desktop disk pressure (image is ~1.5 GB; dataset is ~205 MB) | Low | `make clean` removes everything. Warn in README that ~3 GB of free disk is needed. |
| YARN container OOM on a small laptop | Low-Med | `yarn.nodemanager.pmem-check-enabled=false` and `vmem-check-enabled=false` are in `hadoop.env`. Reducer is single-threaded; map containers are tiny. |
| Hurricane Erin gap in dataset confuses students | Trivial | Gap is in August 1995, not July. Dataset used here is unaffected. README still mentions it as trivia. |
| Combiner not actually invoked (Hadoop sometimes skips it for small splits) | Low | Counter `Combine input records` in JobHistory will be > 0 for the 205 MB input; if zero, force more splits via `mapreduce.input.fileinputformat.split.maxsize`. Documented in M5. |
| Live demo time: jobs slower than expected | Med | Have `sample_output.md` open as a fallback so the slide content does not depend on live execution. M5/M6 capped at 10 min observation. |
| `python3` not in `apache/hadoop:3.4.1` base | Med | The local `Dockerfile` installs it explicitly — this risk is closed by design. |
| Parser regex misses a real-world malformed line variant | Med | Mappers count malformed lines via streaming counters. If the malformed count exceeds 0.1% of input, the M9 unit tests are extended and the regex is hardened. |

## 7. Token inventory and recommended execution order

Estimating Sonnet 4.6 sessions on the Pro plan, where a comfortable session does ~5–10 file touches and ~300–500 lines of code:

| Session | Milestones | Why grouped (or solo) |
|---|---|---|
| **S1** | M1 | Skeleton work; standalone, ends with one git commit. |
| **S2** | M2 | Heaviest single milestone (compose + Dockerfile + healthchecks + verify + `pi` smoke). Solo. |
| **S3a** | M3 | Solo. The two-cycle SHA-256 bootstrap (run → capture hash → edit → re-run → commit) is awkward to interleave with another milestone in the same session. |
| **S3b** | M4 | Solo. Small, depends on M3's committed hash and on M2's running cluster. |
| **S4** | M5 | The pedagogical centerpiece (combiner). Solo. |
| **S5** | M6 | Pattern is established by M5; this session reuses `run_job.sh`. Solo because it has its own verification and commit. |
| **S6** | M7 + M8 | Both are about output and presentation; same Sonnet can chain `make demo` capture into README. |
| **S7** | M9 | Tests. Solo. |

Total: **8 Sonnet sessions** (was 7 before splitting M3/M4).

Recommended order: strictly sequential. Do not parallelize — every milestone depends on the previous one's commit being on disk.

If a session approaches its context limit mid-milestone, the Sonnet should: stop, commit nothing, write a note to `docs/SESSION_NOTES.md` describing exactly what was attempted, and hand back to the user. The next Sonnet picks up from `git status` + that note.
