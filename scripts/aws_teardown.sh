#!/usr/bin/env bash
# scripts/aws_teardown.sh — terminate the NASA MapReduce EC2 instance.
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PROJECT_TAG="${PROJECT_TAG:-nasa-mapreduce}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            "Name=instance-state-name,Values=running,pending,stopped,stopping" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text 2>/dev/null || echo "None")

if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
  echo "No active $PROJECT_TAG instance found in $REGION."
  exit 0
fi

echo "Terminating $INSTANCE_ID..."
aws ec2 terminate-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'TerminatingInstances[].CurrentState.Name' \
  --output text
echo "Done. No further charges."
