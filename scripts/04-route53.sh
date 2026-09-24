#!/usr/bin/env bash
# =============================================================================
# 04-route53.sh
# Creates a Route 53 PRIVATE hosted zone (PRIVATE_ZONE, e.g. selfapp.internal)
# attached to the default VPC, and points db01 / rmq01 at their private IPs.
# The app then connects to db01.selfapp.internal instead of a hard-coded IP —
# the same idea as service names in docker-compose.
# Safe to re-run: records are UPSERTed, so new IPs simply replace old ones.
# Cost: $0.50/month per hosted zone (not Free Tier).
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

step "[04] Route 53 private hosted zone: $PRIVATE_ZONE"

VPC_ID=$(get_vpc_id)
[ -n "$VPC_ID" ] || die "No default VPC found"

# Private zones only resolve if the VPC has DNS support + hostnames enabled
# (true for the default VPC, but checking makes failures obvious).
for ATTR in enableDnsSupport:EnableDnsSupport enableDnsHostnames:EnableDnsHostnames; do
  NAME=${ATTR%%:*} FIELD=${ATTR##*:}
  VALUE=$(aws ec2 describe-vpc-attribute --vpc-id "$VPC_ID" --attribute "$NAME" \
    --query "${FIELD}.Value" --output text)
  [ "$VALUE" = "True" ] || die "VPC $VPC_ID has $NAME disabled. Enable it: aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --$NAME '{\"Value\":true}'"
done

# ---------- Hosted zone (match private zones only, never a public one) ----------
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$PRIVATE_ZONE" \
  --query "HostedZones[?Name=='${PRIVATE_ZONE}.' && Config.PrivateZone] | [0].Id" \
  --output text | none_to_empty)
ZONE_ID=${ZONE_ID##*/}   # "/hostedzone/Z123" → "Z123"

if [ -z "$ZONE_ID" ]; then
  log "Creating private hosted zone: $PRIVATE_ZONE"
  ZONE_ID=$(aws route53 create-hosted-zone \
    --name "$PRIVATE_ZONE" \
    --caller-reference "selfapp-$(date +%s)" \
    --hosted-zone-config Comment="selfapp internal DNS",PrivateZone=true \
    --vpc VPCRegion="$AWS_REGION",VPCId="$VPC_ID" \
    --query 'HostedZone.Id' --output text)
  ZONE_ID=${ZONE_ID##*/}
  aws route53 change-tags-for-resource --resource-type hostedzone \
    --resource-id "$ZONE_ID" --add-tags "Key=Project,Value=$PROJECT_TAG"
else
  log "Zone already exists: $ZONE_ID"
fi

# ---------- A records: one batch, then wait until live ----------
CHANGES=""
for HOST in db01 rmq01; do
  IP=$(get_private_ip "$HOST")
  [ -n "$IP" ] || die "$HOST is not running — run 03-backends.sh first"
  log "${HOST}.${PRIVATE_ZONE} → $IP"
  CHANGES+="${CHANGES:+,}{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${HOST}.${PRIVATE_ZONE}\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${IP}\"}]}}"
done

CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "{\"Comment\":\"selfapp backends\",\"Changes\":[${CHANGES}]}" \
  --query 'ChangeInfo.Id' --output text)

log "Waiting for DNS change to propagate..."
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"

echo ""
step "Done. app01 will reach db01.${PRIVATE_ZONE} and rmq01.${PRIVATE_ZONE}"
log "Next: 05-deploy-app.sh"
