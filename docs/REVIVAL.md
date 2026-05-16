# REVIVAL.md — Automated EC2 Demo Revival Guide
# Audience: Claude (Sonnet/Opus) executing in a new session
# Working directory: /home/clopez/up/ml-big-data
# Last known good run: 2026-05-15

---

## CONSTRAINTS (read before doing anything)

- **SSH is BLOCKED** at the university network. Never attempt SSH or rsync. All remote execution uses AWS SSM Run Command exclusively.
- **Credentials expire** each EPAM lab session. User must provide fresh keys. Use `export`, never `aws configure`.
- **One instance at a time.** Check for running instances before launching. Terminate orphans.
- **Always terminate** when done. m5.xlarge = $0.192/hr. Budget is $50 total.
- **SSM commands are async.** Always poll `get-command-invocation` until Status != InProgress before proceeding.
- **Large files via SSM:** base64-encode locally → send as echo pipe → decode on EC2.
- **Docker build first.** `docker compose up --build` fails on this AMI (buildx version). Always run `docker build` separately first.

---

## STEP 0 — Set credentials

User provides Access Key ID + Secret. Execute:

```bash
export AWS_ACCESS_KEY_ID="<provided>"
export AWS_SECRET_ACCESS_KEY="<provided>"
export AWS_DEFAULT_REGION="us-east-1"
aws sts get-caller-identity  # verify: should show account 023579852268
```

These exports do NOT persist between Bash tool calls. Chain all dependent commands with `&&` in a single call.

---

## STEP 1 — Check for existing running instances

```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,InstanceType,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

- If `i-003b293d36c02e0cd` or any m5.xlarge is running → reuse it, skip Step 2.
- If unknown instances are running → ask user before touching them.
- If nothing running → proceed to Step 2.

---

## STEP 2 — Launch EC2 instance (~2 min)

```bash
make ec2-up
```

This target in the Makefile:
- Finds latest Amazon Linux 2023 AMI
- Reuses key pair `nasa-demo` (file: `nasa-demo.pem`) or creates it
- Launches m5.xlarge with 30 GB gp3, security group `sg-0ce597dbefd715675`
- Runs `scripts/ec2_bootstrap.sh` as User Data (installs Docker + Docker Compose v2)
- Writes instance ID to `.ec2_instance_id`, IP to `.ec2_ip`
- Waits for `instance-running` state

**After `make ec2-up` returns:** wait an additional 3 minutes for User Data (Docker install) to complete before sending SSM commands. Use a single Bash call: `sleep 180 && echo ready`.

**If SSM commands fail with "not connected":** the instance profile may be missing. Add `--iam-instance-profile Name=LabRole` to the `run-instances` call in the Makefile `ec2-up` target and relaunch.

---

## STEP 3 — Upload project via SSM (~1 min)

SSH/rsync are blocked. Pack and upload via base64:

```bash
INSTANCE_ID=$(cat .ec2_instance_id) && \
tar czf /tmp/ml-big-data.tar.gz \
  --exclude='.git' \
  --exclude='data/NASA_*' \
  --exclude='data/output/*' \
  --exclude='nasa-demo.pem' \
  --exclude='.ec2_*' \
  -C /home/clopez/up ml-big-data && \
B64=$(base64 -w0 /tmp/ml-big-data.tar.gz) && \
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"echo '$B64' | base64 -d > /tmp/project.tar.gz && tar xzf /tmp/project.tar.gz -C /home/ec2-user && chown -R ec2-user:ec2-user /home/ec2-user/ml-big-data && echo UPLOAD_DONE\"]" \
  --timeout-seconds 120 \
  --query 'Command.CommandId' --output text) && \
echo "CMD: $CMD_ID"
```

Poll until done:
```bash
aws ssm get-command-invocation \
  --command-id "<CMD_ID>" \
  --instance-id "$(cat .ec2_instance_id)" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' \
  --output text
```

Expected output: `Success  UPLOAD_DONE`

---

## STEP 4 — Build Docker image + start cluster (~5 min)

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$(cat .ec2_instance_id)" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 600 \
  --parameters "commands=[\"cd /home/ec2-user/ml-big-data && docker build -t mapreduce-nasa:3.4.1 . && docker compose up -d --scale datanode=2 --scale nodemanager=2 && echo CLUSTER_UP\"]" \
  --query 'Command.CommandId' --output text) && echo "CMD: $CMD_ID"
```

Poll every 15s. Timeout: 600s. Expected final output: `CLUSTER_UP`.

Verify 7 containers healthy:
```bash
aws ssm send-command \
  --instance-ids "$(cat .ec2_instance_id)" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"docker compose -f /home/ec2-user/ml-big-data/docker-compose.yml ps\"]" \
  --query 'Command.CommandId' --output text
```

---

## STEP 5 — Configure Apache reverse proxy

The dashboard browser fetches YARN (:8088) and HDFS (:9870) APIs. CORS blocks direct calls, so Apache proxies them at /yarn/ and /hdfs/.

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$(cat .ec2_instance_id)" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 60 \
  --parameters "commands=[\"yum install -y httpd && systemctl start httpd && systemctl enable httpd && cat > /etc/httpd/conf.d/hadoop-proxy.conf << 'EOF'\nLoadModule proxy_module modules/mod_proxy.so\nLoadModule proxy_http_module modules/mod_proxy_http.so\nLoadModule headers_module modules/mod_headers.so\nHeader always set Access-Control-Allow-Origin \\\"*\\\"\nProxyPass /yarn/ http://localhost:8088/\nProxyPassReverse /yarn/ http://localhost:8088/\nProxyPass /hdfs/ http://localhost:9870/\nProxyPassReverse /hdfs/ http://localhost:9870/\nEOF\nsystemctl restart httpd && echo APACHE_DONE\"]" \
  --query 'Command.CommandId' --output text) && echo "CMD: $CMD_ID"
```

---

## STEP 6 — Download dataset + load to HDFS (~4 min)

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$(cat .ec2_instance_id)" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 300 \
  --parameters "commands=[\"cd /home/ec2-user/ml-big-data && make download && make load && echo DATA_LOADED\"]" \
  --query 'Command.CommandId' --output text) && echo "CMD: $CMD_ID"
```

Expected: `DATA_LOADED`. Dataset is 205 MB, downloads from NASA FTP mirror.

---

## STEP 7 — Run all 3 MapReduce jobs (~15 min)

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$(cat .ec2_instance_id)" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 1200 \
  --parameters "commands=[\"cd /home/ec2-user/ml-big-data && make job-top && make job-status && make job-hourly && echo JOBS_DONE\"]" \
  --query 'Command.CommandId' --output text) && echo "CMD: $CMD_ID"
```

Poll every 30s. Expected: `JOBS_DONE`. Each job runs 3 reducers producing part-00000/00001/00002.

---

## STEP 8 — Deploy dashboard

Upload `dashboard/index.html` (NASA light-mode theme, Barlow Condensed + Share Tech Mono fonts):

```bash
INSTANCE_ID=$(cat .ec2_instance_id) && \
mkdir -p dashboard/api/results dashboard/api/logs && \
bash scripts/results_to_json.sh && \
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"mkdir -p /var/www/html/api/results /var/www/html/api/logs && echo DIRS_OK\"]" \
  --query 'Command.CommandId' --output text) && \
sleep 5 && \
B64=$(base64 -w0 dashboard/index.html) && \
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"echo '$B64' | base64 -d > /var/www/html/index.html && echo HTML_DONE\"]" \
  --query 'Command.CommandId' --output text) && echo "CMD: $CMD_ID"
```

Upload JSON results (loop for each file: top_resources, status_bytes, hourly_traffic):
```bash
for f in top_resources status_bytes hourly_traffic; do
  B64=$(base64 -w0 dashboard/api/results/$f.json)
  aws ssm send-command \
    --instance-ids "$(cat .ec2_instance_id)" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"echo '$B64' | base64 -d > /var/www/html/api/results/$f.json\"]" \
    --query 'Command.CommandId' --output text
  sleep 3
done
```

---

## STEP 9 — Verify everything

| Check | URL | Expected |
|---|---|---|
| Dashboard | `http://$(cat .ec2_ip)` | NASA theme loads, cluster cards show data |
| YARN UI | `http://$(cat .ec2_ip):8088` | 3 apps with SUCCEEDED status |
| NameNode UI | `http://$(cat .ec2_ip):9870` | Live Datanodes: 2 |
| History Server | `http://$(cat .ec2_ip):19888` | 3 jobs with counters |

---

## STEP 10 — Record demo (user action)

User records screen showing all 4 URLs above. Suggested order:
1. Dashboard (overview)
2. YARN :8088 (jobs table)
3. NameNode :9870 (2 datanodes, replication 2)
4. HistoryServer :19888 (job counters: ~1.89M map input records)

---

## STEP 11 — TERMINATE ⚠️

```bash
make ec2-down
```

Or directly:
```bash
aws ec2 terminate-instances --instance-ids "$(cat .ec2_instance_id)"
```

Confirm status:
```bash
aws ec2 describe-instances \
  --instance-ids "$(cat .ec2_instance_id)" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text
# Expected: terminated (or shutting-down)
```

---

## KNOWN ISSUES & FIXES

| Issue | Fix |
|---|---|
| SSM "not connected" after launch | Wait 3 min for User Data; add `--iam-instance-profile Name=LabRole` to run-instances |
| `docker compose up --build` fails (buildx error) | Run `docker build -t mapreduce-nasa:3.4.1 .` first, then `docker compose up -d` without `--build` |
| CORS errors in dashboard console | Apache proxy not configured — run Step 5 |
| 6 jobs in YARN instead of 3 | Restart resourcemanager: `docker restart nasa-resourcemanager nasa-historyserver` |
| `-D dfs.replication` syntax error in hdfs dfs | Use `-Ddfs.replication=2` (no space after -D) |
| Old access keys (AuthFailure) | User must generate new keys from IAM console |

---

## QUICK REFERENCE

```
Account:         023579852268
Region:          us-east-1
Instance type:   m5.xlarge  ($0.192/hr)
Security group:  sg-0ce597dbefd715675
Key pair name:   nasa-demo
Local key file:  /home/clopez/up/ml-big-data/nasa-demo.pem
Project path:    /home/clopez/up/ml-big-data
EC2 project:     /home/ec2-user/ml-big-data
Dashboard JS:    polls /yarn/ and /hdfs/ (Apache proxy paths, NOT direct ports)
```

## COST ESTIMATE

Total active time ~40 min = **~$0.13**. Budget remaining: ~$49.87.
