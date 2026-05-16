#!/bin/bash
set -euo pipefail
yum update -y
yum install -y docker git make
systemctl start docker
systemctl enable docker
usermod -aG docker ec2-user
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
# signal bootstrap complete
touch /tmp/bootstrap_done
