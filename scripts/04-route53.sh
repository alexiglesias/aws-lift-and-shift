#!/usr/bin/env bash
# =============================================================================
# 04-route53.sh
# Creates the Route 53 private hosted zone (selfapp.internal) and registers
# A records for db01, mc01, rmq01 using their current private IPs.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

echo "==> [04] Setting up Route 53 Private Hosted Zone: $PRIVATE_ZONE"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --region "$AWS_REGION" \
  --query 'Vpcs[0].VpcId' --output text)

# ---------- Create hosted zone if it doesn't exist ----------
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$PRIVATE_ZONE" \
  --query "HostedZones[?Name=='${PRIVATE_ZONE}.'].Id" \
  --output text | cut -d/ -f3)

if [ -z "$ZONE_ID" ]; then
  echo "  Creating private hosted zone: $PRIVATE_ZONE"
  ZONE_ID=$(aws route53 create-hosted-zone \
    --name "$PRIVATE_ZONE" \
    --caller-reference "selfapp-$(date +%s)" \
    --hosted-zone-config Comment="selfapp internal DNS",PrivateZone=true \
    --vpc VPCRegion="$AWS_REGION",VPCId="$VPC_ID" \
    --query 'HostedZone.Id' --output text | cut -d/ -f3)
  echo "  Zone created: $ZONE_ID"
else
  echo "  Zone already exists: $ZONE_ID"
fi

# ---------- Upsert A records ----------
upsert_record() {
  local HOSTNAME=$1
  local IP
  IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${HOSTNAME}" Name=instance-state-name,Values=running \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

  if [ -z "$IP" ] || [ "$IP" = "None" ]; then
    echo "  WARNING: $HOSTNAME not found or not running — skipping DNS record"
    return
  fi

  echo "  ${HOSTNAME}.${PRIVATE_ZONE} → $IP"
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "{
      \"Changes\": [{
        \"Action\": \"UPSERT\",
        \"ResourceRecordSet\": {
          \"Name\": \"${HOSTNAME}.${PRIVATE_ZONE}\",
          \"Type\": \"A\",
          \"TTL\": 300,
          \"ResourceRecords\": [{\"Value\": \"${IP}\"}]
        }
      }]
    }" > /dev/null
}

upsert_record "db01"
upsert_record "mc01"
upsert_record "rmq01"

echo ""
echo "==> Done. DNS records registered in $PRIVATE_ZONE"
echo "    app01 will resolve db01.${PRIVATE_ZONE} to reach MySQL."
echo ""
echo "    Run 05-deploy-app.sh next."
