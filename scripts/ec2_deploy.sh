#!/bin/bash
set -euo pipefail

EC2_IP=$(cat .ec2_ip)
EC2_KEY=$(cat .ec2_key)

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "Waiting for SSH on ${EC2_IP}..."
elapsed=0
while [ $elapsed -lt 180 ]; do
  if ssh $SSH_OPTS -i "$EC2_KEY" ec2-user@"$EC2_IP" true 2>/dev/null; then
    echo "SSH is available."
    break
  fi
  echo "  SSH not ready yet, retrying in 10s..."
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ $elapsed -ge 180 ]; then
  echo "ERROR: SSH not available after 3 minutes." >&2
  exit 1
fi

echo "Waiting for bootstrap to complete on instance..."
elapsed=0
while [ $elapsed -lt 300 ]; do
  if ssh $SSH_OPTS -i "$EC2_KEY" ec2-user@"$EC2_IP" "test -f /tmp/bootstrap_done" 2>/dev/null; then
    echo "Bootstrap complete."
    break
  fi
  echo "  Bootstrap not done yet, retrying in 15s..."
  sleep 15
  elapsed=$((elapsed + 15))
done

if [ $elapsed -ge 300 ]; then
  echo "ERROR: Bootstrap did not complete after 5 minutes." >&2
  exit 1
fi

echo "Syncing project to EC2..."
rsync -avz --progress \
  --exclude 'data/NASA_access_log_Jul95*' \
  --exclude 'data/output/*' \
  --exclude '.git/' \
  --exclude 'nasa-demo.pem' \
  --exclude '*.pem' \
  -e "ssh $SSH_OPTS -i $EC2_KEY" \
  ./ ec2-user@"${EC2_IP}":/home/ec2-user/ml-big-data/

echo "Downloading dataset and loading into HDFS on EC2..."
ssh $SSH_OPTS -i "$EC2_KEY" ec2-user@"$EC2_IP" \
  "cd /home/ec2-user/ml-big-data && make download && make load"

echo "Deploy complete. Dataset is loaded into HDFS on EC2."
