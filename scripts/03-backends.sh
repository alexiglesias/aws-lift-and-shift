#!/usr/bin/env bash
# =============================================================================
# 03-backends.sh
# Launches db01 (MySQL), mc01 (Memcached), rmq01 (RabbitMQ) EC2 instances.
# Substitutes credentials into userdata scripts before sending to EC2.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

USERDATA_DIR="$(dirname "$0")/../userdata"

echo "==> [03] Launching backend EC2 instances"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --region "$AWS_REGION" \
  --query 'Vpcs[0].VpcId' --output text)

BACKEND_SG=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=selfapp-backend-sg Name=vpc-id,Values="$VPC_ID" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' --output text)

# Helper: launch or skip if instance already running
launch_instance() {
  local NAME=$1 USERDATA_FILE=$2

  EXISTING=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" Name=instance-state-name,Values=running,pending \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "None")

  if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
    echo "  $NAME already running ($EXISTING) — skipping"
    return
  fi

  echo "  Launching $NAME..."
  aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --key-name "$KEY_NAME" \
    --security-group-ids "$BACKEND_SG" \
    --user-data file://"$USERDATA_FILE" \
    --region "$AWS_REGION" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=selfapp-lift-shift}]" \
    --query 'Instances[0].InstanceId' --output text
}

# Substitute credentials into db01 userdata
DB01_SCRIPT=$(mktemp)
sed \
  -e "s/__DB_ROOT_PASS__/${DB_ROOT_PASS}/g" \
  -e "s/__DB_NAME__/${DB_NAME}/g" \
  -e "s/__DB_USER__/${DB_USER}/g" \
  -e "s/__DB_PASS__/${DB_PASS}/g" \
  "$USERDATA_DIR/db01.sh" > "$DB01_SCRIPT"

launch_instance "db01"  "$DB01_SCRIPT"
launch_instance "mc01"  "$USERDATA_DIR/mc01.sh"
launch_instance "rmq01" "$USERDATA_DIR/rmq01.sh"

rm -f "$DB01_SCRIPT"

echo ""
echo "==> Backend instances launched. Waiting for them to reach 'running' state..."
aws ec2 wait instance-running \
  --filters "Name=tag:Project,Values=selfapp-lift-shift" \
            "Name=tag:Name,Values=db01" \
  --region "$AWS_REGION"

echo ""
echo "==> Instance private IPs:"
for NAME in db01 mc01 rmq01; do
  IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" Name=instance-state-name,Values=running \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  echo "    $NAME → $IP"
done

echo ""
echo "    Run 04-route53.sh next to register these IPs in DNS."
