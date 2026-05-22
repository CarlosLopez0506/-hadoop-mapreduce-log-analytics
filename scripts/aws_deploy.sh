#!/usr/bin/env bash
# scripts/aws_deploy.sh
#
# Provision an EC2 instance and deploy the NASA MapReduce demo end-to-end
# using AWS SSM Run Command (no SSH, no Ansible). Each step is an idempotent
# SSM RPC that AWS queues until the agent is ready — robust to the transient
# TargetNotConnected windows that broke the Ansible approach.
#
# Usage:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_DEFAULT_REGION=us-east-1
#   export REPO_URL=https://github.com/<user>/ml-big-data
#   bash scripts/aws_deploy.sh
#
# Teardown:
#   bash scripts/aws_teardown.sh

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-m5.xlarge}"
SG_ID="${SG_ID:-sg-0ce597dbefd715675}"
IAM_PROFILE="${IAM_PROFILE:-rolEC2}"
PROJECT_TAG="${PROJECT_TAG:-nasa-mapreduce}"
BRANCH="${BRANCH:-master}"
PROJECT_DIR="/home/ec2-user/ml-big-data"
REPO_URL="${REPO_URL:?REPO_URL env var required (e.g. https://github.com/user/ml-big-data)}"

BOLD=$'\e[1m'; DIM=$'\e[2m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
RED=$'\e[31m'; BLUE=$'\e[34m'; NC=$'\e[0m'

STEP=0
TOTAL_STEPS=13
SCRIPT_START=$(date +%s)

step()  { STEP=$((STEP+1)); echo; echo "${BOLD}[${STEP}/${TOTAL_STEPS}] $*${NC}"; }
info()  { echo "  ${DIM}$*${NC}"; }
ok()    { echo "  ${GREEN}✓${NC} $*"; }
warn()  { echo "  ${YELLOW}!${NC} $*" >&2; }
die()   { echo "  ${RED}✗${NC} $*" >&2; exit 1; }

fmt_duration() {
  local s=$1
  printf '%dm%02ds' $((s/60)) $((s%60))
}

# ssm_run "label" "shell_command" [timeout_seconds]
# Sends a Run Command, polls until it completes, prints output tail on success
# and full stderr on failure. Returns the command's exit status.
ssm_run() {
  local label="$1"
  local cmd="$2"
  local timeout="${3:-600}"
  local start; start=$(date +%s)

  info "$label"

  # Marshal the command into JSON safely.
  local params
  params=$(python3 -c '
import json, sys
print(json.dumps({"commands": [sys.argv[1]]}))
' "$cmd")

  # send-command can briefly fail with InvalidInstanceId if the agent has not
  # registered yet. Retry up to 12x (1 min) before giving up.
  local cmd_id="" attempt=0
  while [[ -z "$cmd_id" ]]; do
    cmd_id=$(aws ssm send-command \
      --region "$REGION" \
      --instance-ids "$INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --timeout-seconds "$timeout" \
      --parameters "$params" \
      --query 'Command.CommandId' \
      --output text 2>/dev/null || echo "")
    if [[ -z "$cmd_id" ]]; then
      attempt=$((attempt+1))
      [[ $attempt -ge 12 ]] && die "send-command failed after 12 retries"
      sleep 5
    fi
  done

  # Poll until terminal state.
  local status="" out="" err=""
  while true; do
    sleep 5
    local result
    result=$(aws ssm get-command-invocation \
      --region "$REGION" \
      --command-id "$cmd_id" \
      --instance-id "$INSTANCE_ID" \
      --output json 2>/dev/null || echo '{"Status":"Unknown"}')
    status=$(echo "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Status",""))')
    case "$status" in
      Success)
        local elapsed=$(($(date +%s) - start))
        out=$(echo "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("StandardOutputContent",""))')
        # Show last 3 lines of output for context.
        if [[ -n "$out" ]]; then
          echo "$out" | tail -n 3 | sed "s/^/    ${DIM}/" | sed "s/\$/${NC}/"
        fi
        ok "$label ($(fmt_duration $elapsed))"
        return 0
        ;;
      Failed|Cancelled|TimedOut)
        err=$(echo "$result" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("StandardErrorContent","") or r.get("StandardOutputContent",""))')
        echo "$err" | tail -n 20 | sed "s/^/    ${RED}/" | sed "s/\$/${NC}/" >&2
        die "$label → $status"
        ;;
      Pending|InProgress|Delayed|Unknown)
        : # keep polling
        ;;
      *)
        die "Unexpected SSM status: $status"
        ;;
    esac
  done
}

# Sanity checks
command -v aws        >/dev/null || die "aws CLI not found"
command -v python3    >/dev/null || die "python3 not found"
[[ -n "${AWS_ACCESS_KEY_ID:-}"     ]] || die "AWS_ACCESS_KEY_ID not set"
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY not set"

echo "${BOLD}NASA MapReduce — AWS deploy${NC}"
echo "  region        : $REGION"
echo "  instance type : $INSTANCE_TYPE"
echo "  branch        : $BRANCH"
echo "  repo          : $REPO_URL"

# ─── Step 1: Find AMI ────────────────────────────────────────────────
step "Resolving latest Amazon Linux 2023 AMI"
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
ok "AMI $AMI_ID"

# ─── Step 2: Launch (or reuse) instance ──────────────────────────────
step "Launching EC2 instance (idempotent on Project tag)"
INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text 2>/dev/null || echo "None")

if [[ "$INSTANCE_ID" != "None" && -n "$INSTANCE_ID" ]]; then
  info "Reusing existing instance $INSTANCE_ID"
else
  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$IAM_PROFILE" \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
    --user-data "file://scripts/ec2_bootstrap.sh" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$PROJECT_TAG},{Key=Name,Value=$PROJECT_TAG}]" \
    --query 'Instances[0].InstanceId' \
    --output text)
  info "Waiting for instance to enter running state"
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
fi

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
ok "Instance $INSTANCE_ID @ $PUBLIC_IP"

# ─── Step 3: Wait for SSM agent registration ─────────────────────────
step "Waiting for SSM agent to register with the service"
for i in {1..72}; do
  status=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "")
  if [[ "$status" == "Online" ]]; then
    ok "SSM agent Online"
    break
  fi
  [[ $i -eq 72 ]] && die "SSM agent did not come online in 6 min"
  sleep 5
done

# ─── Step 4: Wait for bootstrap to finish ────────────────────────────
step "Waiting for User Data bootstrap (Docker install) to finish"
ssm_run "Polling /tmp/bootstrap_done (up to 10 min)" \
"for i in \$(seq 1 120); do
  if [ -f /tmp/bootstrap_done ]; then echo \"bootstrap ready (\${i}0s)\"; exit 0; fi
  sleep 5
done
echo 'bootstrap never completed'; exit 1" 720

# ─── Step 5: Clone or update repo ────────────────────────────────────
step "Cloning project repo (branch=$BRANCH)"
ssm_run "git clone/update + chown" "
set -euo pipefail
if [ -d $PROJECT_DIR/.git ]; then
  cd $PROJECT_DIR
  git fetch origin
  git reset --hard origin/$BRANCH
else
  git clone -b $BRANCH $REPO_URL $PROJECT_DIR
fi
chown -R ec2-user:ec2-user $PROJECT_DIR
echo \"repo at \$(cd $PROJECT_DIR && git rev-parse --short HEAD)\"
" 300

# ─── Step 6: Build Docker image ──────────────────────────────────────
step "Building Docker image (this is the longest step)"
ssm_run "docker build" "
cd $PROJECT_DIR
docker build -t mapreduce-nasa:3.4.1 . > /tmp/build.log 2>&1
tail -3 /tmp/build.log
" 1800

# ─── Step 7: Start cluster ───────────────────────────────────────────
step "Starting Hadoop cluster (2 datanodes + 2 nodemanagers)"
ssm_run "docker compose up + healthcheck" "
set -euo pipefail
cd $PROJECT_DIR
docker compose up -d --scale datanode=2 --scale nodemanager=2 > /tmp/compose.log 2>&1
for i in \$(seq 1 60); do
  count=\$(docker compose ps --format json | python3 -c \"
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip()]
print(sum(1 for r in rows if r.get('Health') == 'healthy'))
\")
  if [ \"\$count\" -ge 7 ]; then echo \"7 containers healthy after \${i}0s\"; exit 0; fi
  sleep 10
done
echo 'cluster never became healthy'; docker compose ps; exit 1
" 900

# ─── Step 8: Download dataset ────────────────────────────────────────
step "Downloading NASA dataset and verifying SHA-256"
ssm_run "scripts/download_dataset.sh" "cd $PROJECT_DIR && bash scripts/download_dataset.sh" 600

# ─── Step 9: Load to HDFS ────────────────────────────────────────────
step "Loading dataset into HDFS (replication=2)"
ssm_run "scripts/load_to_hdfs.sh" "cd $PROJECT_DIR && bash scripts/load_to_hdfs.sh" 600

# ─── Step 10: Run jobs ───────────────────────────────────────────────
step "Running the 3 MapReduce jobs"
ssm_run "Job 1 — top_resources" "cd $PROJECT_DIR && bash scripts/run_job.sh top_resources 2>&1 | tee data/output/top_resources.log | tail -5" 600
ssm_run "Job 2 — status_bytes"  "cd $PROJECT_DIR && bash scripts/run_job.sh status_bytes  2>&1 | tee data/output/status_bytes.log  | tail -5" 600
ssm_run "Job 3 — hourly_traffic" "cd $PROJECT_DIR && bash scripts/run_job.sh hourly_traffic 2>&1 | tee data/output/hourly_traffic.log | tail -5" 600

# ─── Step 11: Sort outputs ───────────────────────────────────────────
step "Sorting job outputs into final tables"
ssm_run "sort -k* per job" "
cd $PROJECT_DIR
sort -k2 -n -r data/output/top_resources.raw.txt | head -20 > data/output/top_resources.txt
sort -k1 -n      data/output/status_bytes.raw.txt          > data/output/status_bytes.txt
sort -k1 -n      data/output/hourly_traffic.raw.txt        > data/output/hourly_traffic.txt
wc -l data/output/*.txt
"

# ─── Step 12: Install Apache + dashboard ─────────────────────────────
step "Installing Apache and deploying dashboard"
ssm_run "yum install httpd + reverse proxy" "
set -euo pipefail
yum install -y httpd > /dev/null
systemctl enable --now httpd
cat > /etc/httpd/conf.d/hadoop-proxy.conf <<'EOF'
Header always set Access-Control-Allow-Origin \"*\"
ProxyPass /yarn/ http://localhost:8088/
ProxyPassReverse /yarn/ http://localhost:8088/
ProxyPass /hdfs/ http://localhost:9870/
ProxyPassReverse /hdfs/ http://localhost:9870/
EOF
systemctl restart httpd
echo 'httpd up'
" 300

ssm_run "generate JSON + deploy index.html" "
set -euo pipefail
cd $PROJECT_DIR
bash scripts/results_to_json.sh
mkdir -p /var/www/html/api/results /var/www/html/api/logs
cp dashboard/index.html /var/www/html/index.html
cp dashboard/api/results/*.json /var/www/html/api/results/
cat data/output/*.log > /var/www/html/api/logs/current.txt
echo 'dashboard deployed'
"

# ─── Step 13: Done ───────────────────────────────────────────────────
step "Done"
TOTAL=$(($(date +%s) - SCRIPT_START))
echo
echo "${BOLD}${GREEN}Deployment complete in $(fmt_duration $TOTAL).${NC}"
echo
echo "  Dashboard    ${BOLD}http://$PUBLIC_IP${NC}"
echo "  YARN UI      http://$PUBLIC_IP:8088"
echo "  NameNode UI  http://$PUBLIC_IP:9870"
echo "  History      http://$PUBLIC_IP:19888"
echo
echo "  When you're done, terminate the instance:"
echo "    ${DIM}bash scripts/aws_teardown.sh${NC}"
echo
