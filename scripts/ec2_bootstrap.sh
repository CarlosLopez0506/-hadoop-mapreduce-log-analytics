#!/bin/bash
set -euo pipefail
# Exclude amazon-ssm-agent from updates — updating it restarts the agent
# mid-session and kills Ansible's active SSM connection.
yum update -y --exclude=amazon-ssm-agent
yum install -y docker git make
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# yum update can disturb network drivers and briefly disconnect the SSM agent
# from the AWS SSM service. Restart the agent and wait for it to re-register
# so that subsequent meta:reset_connection calls don't fail with TargetNotConnected.
systemctl restart amazon-ssm-agent
sleep 30

# signal bootstrap complete
touch /tmp/bootstrap_done
