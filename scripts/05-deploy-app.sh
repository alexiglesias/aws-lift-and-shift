#!/usr/bin/env bash
# =============================================================================
# 05-deploy-app.sh
# 1. Builds the selfapp-lite JAR locally (Java 17 + Maven)
# 2. Uploads it to a private, encrypted S3 bucket
# 3. Launches app01 — a single app server, the classic "rehost" step
#
# Once the ASG exists (07-asg.sh), app01 is no longer launched: re-run this
# script to upload a new build, then roll it out with:
#   bash scripts/07-asg.sh --refresh
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
init_account

step "[05] Build JAR, upload to S3, launch app01"

# ---------- Build ----------
command -v mvn >/dev/null || die "Maven not found. Install Maven and Java 17 first."
APP_DIR=$(cd "$ROOT_DIR" && cd "$APP_SRC_DIR" 2>/dev/null && pwd) \
  || die "APP_SRC_DIR='$APP_SRC_DIR' not found (relative to $ROOT_DIR)"
[ -f "$APP_DIR/pom.xml" ] || die "No pom.xml in $APP_DIR — point APP_SRC_DIR at the Maven project folder"

log "Building $APP_DIR ..."
mvn -B -q -f "$APP_DIR/pom.xml" clean package -DskipTests
JAR=$(find "$APP_DIR/target" -maxdepth 1 -name 'selfapp-lite-*.jar' ! -name '*-plain.jar' | head -1)
[ -n "$JAR" ] || die "Build finished but no selfapp-lite-*.jar found in $APP_DIR/target"
log "Built: $(basename "$JAR")"

# ---------- S3 bucket ----------
if HEAD_ERR=$(aws s3api head-bucket --bucket "$BUCKET_NAME" 2>&1); then
  log "Bucket s3://$BUCKET_NAME already exists"
elif grep -q '404\|Not Found' <<<"$HEAD_ERR"; then
  log "Creating bucket s3://$BUCKET_NAME"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" > /dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
  fi
  aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" \
    --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG}]"
else
  die "Can't use bucket '$BUCKET_NAME' (owned by another account?): $HEAD_ERR"
fi

log "Uploading JAR → s3://$BUCKET_NAME/$JAR_KEY"
aws s3 cp "$JAR" "s3://$BUCKET_NAME/$JAR_KEY" --only-show-errors

# ---------- app01 ----------
if asg_exists; then
  echo ""
  step "Done. The ASG manages the app tier now, so app01 was not launched."
  log "Roll out the new JAR with: bash scripts/07-asg.sh --refresh"
  exit 0
fi

APP_SG=$(get_sg_id "$APP_SG_NAME")
[ -n "$APP_SG" ] || die "Security group '$APP_SG_NAME' not found — run 01-security-groups.sh first"

INSTANCE_ID=$(get_instance_id app01)
if [ -n "$INSTANCE_ID" ]; then
  log "app01 already exists ($INSTANCE_ID) — skipping launch"
  log "(The new JAR is only picked up at boot; to redeploy, terminate app01 and re-run.)"
else
  USERDATA=$(mktemp)
  trap 'rm -f "$USERDATA"' EXIT
  render_template "$ROOT_DIR/userdata/app01.sh" > "$USERDATA"
  INSTANCE_ID=$(launch_instance app01 "$APP_SG" "$USERDATA")
  log "Launched app01: $INSTANCE_ID"
fi

log "Waiting for app01 to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo ""
step "app01 is running: $PUBLIC_IP"
log "Java install + Spring Boot startup take ~2-4 min. To watch it:"
log "  ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
log "  sudo tail -f /var/log/userdata-app01.log   # bootstrap"
log "  sudo journalctl -u selfapp -f               # application"
log "  curl -s localhost:8080/actuator/health"
log "Next: 06-alb.sh"
