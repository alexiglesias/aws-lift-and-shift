#!/usr/bin/env bash
# =============================================================================
# 99-teardown.sh
# Deletes EVERYTHING this project created, in dependency order:
#
#   ASG → launch template → instances → ALB → target group → DNS records
#   → hosted zone → S3 bucket → SSM secrets → IAM → security groups → key pair
#
# Order matters: deleting instances before the ASG makes the ASG launch
# replacements; security groups can't be deleted while ALB network
# interfaces or other groups still reference them.
#
# Safe to re-run: anything already gone is skipped. Also removes resources
# named by the original version of this repo (selfapp-ELB-sg,
# selfapp-ec2-s3-role, mc01).
#
# Usage:
#   bash scripts/99-teardown.sh         # asks for confirmation
#   bash scripts/99-teardown.sh --yes   # no prompt (automation)
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
init_account

case "${1:-}" in
  --yes) CONFIRMED=true ;;
  "") CONFIRMED=false ;;
  *) die "Unknown option '$1'. Usage: $0 [--yes]" ;;
esac

step "[99] Teardown — account $ACCOUNT_ID, region $AWS_REGION"
log "This permanently deletes all '$PROJECT_TAG' resources, including the"
log "database on db01 and the S3 bucket s3://$BUCKET_NAME."
if [ "$CONFIRMED" = false ]; then
  [ -t 0 ] || die "Not running interactively. Re-run with --yes to confirm."
  read -r -p "  Type 'delete' to continue: " ANSWER
  [ "$ANSWER" = "delete" ] || die "Aborted — nothing was deleted."
fi

# ---------- 1. Auto Scaling Group (first, or it replaces what we terminate) ----------
if asg_exists; then
  log "Deleting ASG $ASG_NAME (terminates its instances)..."
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --force-delete
  for _ in $(seq 1 60); do
    asg_exists || break
    sleep 10
  done
  asg_exists && die "ASG still deleting after 10 min — re-run this script later"
  log "ASG deleted"
fi

if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" &>/dev/null; then
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME" > /dev/null
  log "Deleted launch template $LT_NAME"
fi

# ---------- 2. Remaining instances (db01, rmq01, app01, legacy mc01) ----------
# Each launch is its own reservation → one line per instance in text output,
# so flatten to a single line before reading into an array.
read -r -a INSTANCE_IDS <<<"$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t\n' '  ')"
if [ ${#INSTANCE_IDS[@]} -gt 0 ]; then
  log "Terminating ${INSTANCE_IDS[*]}..."
  aws ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}" > /dev/null
  aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}"
  log "Instances terminated"
fi

# ---------- 3. Load balancer (listeners go with it), then target group ----------
ALB_ARN=$(get_alb_arn)
if [ -n "$ALB_ARN" ]; then
  log "Deleting ALB $ALB_NAME..."
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
  log "ALB deleted"
fi

TG_ARN=$(get_tg_arn)
if [ -n "$TG_ARN" ]; then
  aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
  log "Deleted target group $TG_NAME"
fi

# ---------- 4. Private hosted zone (must be emptied first) ----------
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$PRIVATE_ZONE" \
  --query "HostedZones[?Name=='${PRIVATE_ZONE}.' && Config.PrivateZone] | [0].Id" \
  --output text | none_to_empty)
ZONE_ID=${ZONE_ID##*/}
if [ -n "$ZONE_ID" ]; then
  # Every record except the zone's own SOA/NS. Our records are simple
  # single-value A records, so name/type/ttl/value is enough to delete them.
  CHANGES=""
  while read -r R_NAME R_TYPE R_TTL R_VALUE; do
    [ -n "$R_NAME" ] || continue
    CHANGES+="${CHANGES:+,}{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"$R_NAME\",\"Type\":\"$R_TYPE\",\"TTL\":$R_TTL,\"ResourceRecords\":[{\"Value\":\"$R_VALUE\"}]}}"
  done < <(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Type!='SOA' && Type!='NS'].[Name, Type, TTL, ResourceRecords[0].Value]" \
    --output text)
  if [ -n "$CHANGES" ]; then
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
      --change-batch "{\"Changes\":[${CHANGES}]}" > /dev/null
  fi
  aws route53 delete-hosted-zone --id "$ZONE_ID" > /dev/null
  log "Deleted hosted zone $PRIVATE_ZONE ($ZONE_ID)"
fi

# ---------- 5. S3 bucket ----------
if aws s3api head-bucket --bucket "$BUCKET_NAME" &>/dev/null; then
  aws s3 rb "s3://$BUCKET_NAME" --force > /dev/null
  log "Deleted bucket s3://$BUCKET_NAME"
fi

# ---------- 6. SSM secrets ----------
PARAMS=("$SSM_PREFIX/db-pass" "$SSM_PREFIX/db-root-pass" "$SSM_PREFIX/rmq-pass")
DELETED=$(aws ssm delete-parameters --names "${PARAMS[@]}" \
  --query 'length(DeletedParameters)' --output text)
[ "$DELETED" = "0" ] || log "Deleted $DELETED SSM parameter(s) under $SSM_PREFIX"

# ---------- 7. IAM (current + legacy role names) ----------
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" &>/dev/null; then
  for ROLE in $(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
      --query 'InstanceProfile.Roles[].RoleName' --output text); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE"
  done
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME"
  log "Deleted instance profile $PROFILE_NAME"
fi

for ROLE in "$ROLE_NAME" selfapp-ec2-s3-role; do
  aws iam get-role --role-name "$ROLE" &>/dev/null || continue
  for POLICY in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY"
  done
  for POLICY_ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" \
      --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN"
  done
  aws iam delete-role --role-name "$ROLE"
  log "Deleted IAM role $ROLE"
done

# ---------- 8. Security groups (backend → app → elb, retrying) ----------
# ALB network interfaces can linger for a few minutes after the ALB is gone,
# which makes deletion fail with DependencyViolation — so retry.
delete_sg() {  # $1 = name
  local id out
  id=$(get_sg_id "$1")
  [ -n "$id" ] || return 0
  for _ in $(seq 1 30); do
    if out=$(aws ec2 delete-security-group --group-id "$id" 2>&1); then
      log "Deleted security group $1"
      return 0
    fi
    grep -q 'DependencyViolation' <<<"$out" || die "Could not delete $1: $out"
    sleep 10
  done
  die "Security group $1 is still in use after 5 min — re-run this script later"
}
for SG in "$BACKEND_SG_NAME" "$APP_SG_NAME" "$ELB_SG_NAME" selfapp-ELB-sg; do
  delete_sg "$SG"
done

# ---------- 9. Key pair ----------
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
  aws ec2 delete-key-pair --key-name "$KEY_NAME" > /dev/null
  log "Deleted key pair $KEY_NAME"
fi
if [ -f "$HOME/.ssh/${KEY_NAME}.pem" ]; then
  rm -f "$HOME/.ssh/${KEY_NAME}.pem"
  log "Removed ~/.ssh/${KEY_NAME}.pem (useless without the AWS key pair)"
fi

echo ""
step "Teardown complete. Verify nothing is left with:"
log "aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=$PROJECT_TAG"
log "(Terminated instances and deleted resources can show up there for ~1 hour.)"
