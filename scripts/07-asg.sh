#!/usr/bin/env bash
# =============================================================================
# 07-asg.sh
# Moves the app tier from one hand-launched server (app01) to an Auto
# Scaling Group:
#   Launch template (same settings + user data as app01)
#   → ASG: min 1 / max 3, spread across AZs, registered in the target group,
#     replaces instances the ALB marks unhealthy
#   → target tracking policy: scale out when average CPU > 70%
#
# Re-running is safe. If the launch template's content changed, a new version
# is created and the ASG rolls it out with a zero-downtime instance refresh.
#
# Usage:
#   bash scripts/07-asg.sh            # create / update
#   bash scripts/07-asg.sh --refresh  # also force a rollout (e.g. new JAR in S3)
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
init_account

FORCE_REFRESH=false
case "${1:-}" in
  --refresh) FORCE_REFRESH=true ;;
  "") ;;
  *) die "Unknown option '$1'. Usage: $0 [--refresh]" ;;
esac

step "[07] Launch template and Auto Scaling Group"

APP_SG=$(get_sg_id "$APP_SG_NAME")
PROFILE_ARN=$(get_profile_arn)
TG_ARN=$(get_tg_arn)
[ -n "$APP_SG" ]      || die "Security group '$APP_SG_NAME' not found — run 01-security-groups.sh first"
[ -n "$PROFILE_ARN" ] || die "Instance profile not found — run 02-iam.sh first"
[ -n "$TG_ARN" ]      || die "Target group '$TG_NAME' not found — run 06-alb.sh first"

# ---------- Launch template data ----------
USERDATA=$(mktemp)
trap 'rm -f "$USERDATA"' EXIT
render_template "$ROOT_DIR/userdata/app01.sh" > "$USERDATA"
# Portable: GNU base64 wraps lines at 76 chars (which breaks the JSON below)
# and macOS base64 doesn't — stripping newlines works on both.
USERDATA_B64=$(base64 < "$USERDATA" | tr -d '\n')

CREDIT_SPEC=""
[[ "$INSTANCE_TYPE" == t* ]] && CREDIT_SPEC='"CreditSpecification": {"CpuCredits": "standard"},'

LT_DATA=$(cat <<JSON
{
  "ImageId": "${AMI_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "KeyName": "${KEY_NAME}",
  "SecurityGroupIds": ["${APP_SG}"],
  "IamInstanceProfile": {"Arn": "${PROFILE_ARN}"},
  "MetadataOptions": {"HttpTokens": "required", "HttpEndpoint": "enabled"},
  ${CREDIT_SPEC}
  "UserData": "${USERDATA_B64}",
  "TagSpecifications": [
    {"ResourceType": "instance", "Tags": [{"Key": "Name", "Value": "app-asg"}, {"Key": "Project", "Value": "${PROJECT_TAG}"}]},
    {"ResourceType": "volume",   "Tags": [{"Key": "Name", "Value": "app-asg"}, {"Key": "Project", "Value": "${PROJECT_TAG}"}]}
  ]
}
JSON
)
# Fingerprint of the desired config, stored as the version description, so a
# re-run can tell whether anything actually changed.
LT_HASH="cksum:$(printf '%s' "$LT_DATA" | cksum | awk '{print $1}')"

# ---------- Launch template (create, or add a version if changed) ----------
NEW_VERSION=false
if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" &>/dev/null; then
  LATEST_HASH=$(aws ec2 describe-launch-template-versions \
    --launch-template-name "$LT_NAME" --versions '$Latest' \
    --query 'LaunchTemplateVersions[0].VersionDescription' --output text)
  if [ "$LATEST_HASH" = "$LT_HASH" ]; then
    log "Launch template '$LT_NAME' is up to date"
  else
    VERSION=$(aws ec2 create-launch-template-version \
      --launch-template-name "$LT_NAME" \
      --version-description "$LT_HASH" \
      --launch-template-data "$LT_DATA" \
      --query 'LaunchTemplateVersion.VersionNumber' --output text)
    log "Config changed — created launch template version $VERSION"
    NEW_VERSION=true
  fi
else
  log "Creating launch template: $LT_NAME"
  aws ec2 create-launch-template \
    --launch-template-name "$LT_NAME" \
    --version-description "$LT_HASH" \
    --launch-template-data "$LT_DATA" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Project,Value=$PROJECT_TAG}]" > /dev/null
fi

# ---------- Auto Scaling Group ----------
SUBNETS=$(get_default_subnets | tr ' ' ',')
if asg_exists; then
  log "Updating ASG: $ASG_NAME"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
    --min-size 1 --max-size 3 \
    --vpc-zone-identifier "$SUBNETS" \
    --health-check-type ELB --health-check-grace-period 300 \
    --default-instance-warmup 300
  ASG_IS_NEW=false
else
  log "Creating ASG: $ASG_NAME (min 1, max 3)"
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
    --min-size 1 --max-size 3 --desired-capacity 1 \
    --target-group-arns "$TG_ARN" \
    --vpc-zone-identifier "$SUBNETS" \
    --health-check-type ELB --health-check-grace-period 300 \
    --default-instance-warmup 300 \
    --tags "Key=Project,Value=$PROJECT_TAG,PropagateAtLaunch=true"
  ASG_IS_NEW=true
fi
# Grace period 300s: dnf upgrade + Java install + Spring Boot startup on a
# t2.micro takes a few minutes; a shorter grace would kill instances that
# are still booting and loop forever.

aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-name selfapp-cpu-70 \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration \
    '{"PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},"TargetValue":70.0}' \
  > /dev/null
log "Target tracking policy: average CPU 70%"

# ---------- Rolling update ----------
# Launch-before-terminate (min 100% / max 200% healthy) = no downtime.
if [ "$ASG_IS_NEW" = false ] && { [ "$NEW_VERSION" = true ] || [ "$FORCE_REFRESH" = true ]; }; then
  if OUT=$(aws autoscaling start-instance-refresh \
      --auto-scaling-group-name "$ASG_NAME" \
      --preferences '{"MinHealthyPercentage":100,"MaxHealthyPercentage":200,"InstanceWarmup":300}' \
      --query InstanceRefreshId --output text 2>&1); then
    log "Started instance refresh $OUT (new instances replace old ones one by one)"
    log "Track it: aws autoscaling describe-instance-refreshes --auto-scaling-group-name $ASG_NAME"
  elif grep -q 'InstanceRefreshInProgress' <<<"$OUT"; then
    warn "An instance refresh is already running — not starting another"
  else
    die "Instance refresh failed: $OUT"
  fi
fi

echo ""
step "Done. ASG '$ASG_NAME' is managing the app tier."
APP01_ID=$(get_instance_id app01)
if [ -n "$APP01_ID" ]; then
  log "Once the ASG instance shows 'healthy' in the target group, retire app01:"
  log "  aws ec2 terminate-instances --instance-ids $APP01_ID"
fi
log "Next: 08-validate.sh"
