#!/bin/bash
# EC2 User Data — runs once on instance launch. Installs Docker and signals
# completion via /tmp/bootstrap_done so the deploy script knows when to start.
set -euo pipefail

# amazon-ssm-agent comes preinstalled on AL2023. Exclude it from updates so we
# don't disturb the agent's registration mid-bootstrap.
yum update -y --exclude=amazon-ssm-agent
yum install -y docker git make

systemctl enable --now docker
usermod -aG docker ec2-user

mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

touch /tmp/bootstrap_done
