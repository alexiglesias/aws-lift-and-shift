#!/usr/bin/env bash
# =============================================================================
# 05-deploy-app.sh
# 1. Builds the JAR locally (requires Java 17 + Maven)
# 2. Creates the S3 bucket and uploads the JAR
# 3. Launches app01 EC2 with the substituted userdata script
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

REPO_ROOT="$(dirname "$0")/../.."
USERDATA_DIR="$(dirname "$0")/../userdata"

echo "==> [05] Build JAR, upload to S3, launch app01"

# ---------- Resolve bucket name ----------
if [ -z "$BUCKET_NAME" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  BUCKET_NAME="selfapp-artifacts-${ACCOUNT_ID}"
fi
echo "  S3 bucket: $BUCKET_NAME"

# ---------- Build ----------
echo "  Building selfapp-lite..."
(cd "$REPO_ROOT/app" && mvn -B clean package -DskipTests -q)
JAR=$(ls "$REPO_ROOT/app/target/selfapp-lite-"*.jar | head -1)
echo "  JAR: $JAR"

# ---------- S3 bucket ----------
if ! aws s3 ls "s3://$BUCKET_NAME" --region "$AWS_REGION" &>/dev/null; then
  echo "  Creating S3 bucket: $BUCKET_NAME"
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3 mb "s3://$BUCKET_NAME" --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
fi

echo "  Uploading JAR to S3..."
aws s3 cp "$JAR" "s3://${BUCKET_NAME}/selfapp-lite-1.0.0.jar"

# ---------- Prepare userdata ----------
APP01_SCRIPT=$(mktemp)
sed \
  -e "s/__BUCKET_NAME__/${BUCKET_NAME}/g" \
  -e "s/__PRIVATE_ZONE__/${PRIVATE_ZONE}/g" \
  -e "s/__DB_NAME__/${DB_NAME}/g" \
  -e "s/__DB_USER__/${DB_USER}/g" \
  -e "s/__DB_PASS__/${DB_PASS}/g" \
  "$USERDATA_DIR/app01.sh" > "$APP01_SCRIPT"

# ---------- Launch app01 ----------
VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --region "$AWS_REGION" \
  --query 'Vpcs[0].VpcId' --output text)

APP_SG=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=selfapp-app-sg Name=vpc-id,Values="$VPC_ID" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' --output text)

PROFILE_ARN=$(aws iam get-instance-profile \
  --instance-profile-name selfapp-ec2-profile \
  --query 'InstanceProfile.Arn' --output text)

EXISTING=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=app01" Name=instance-state-name,Values=running,pending \
  --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "None")

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
  echo "  app01 already running ($EXISTING) — skipping launch"
else
  echo "  Launching app01..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t2.micro \
    --key-name "$KEY_NAME" \
    --security-group-ids "$APP_SG" \
    --iam-instance-profile Arn="$PROFILE_ARN" \
    --user-data file://"$APP01_SCRIPT" \
    --region "$AWS_REGION" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=app01},{Key=Project,Value=selfapp-lift-shift}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "  Instance ID: $INSTANCE_ID"
fi

rm -f "$APP01_SCRIPT"

echo ""
echo "==> app01 launched. Waiting for it to reach 'running'..."
aws ec2 wait instance-running \
  --filters "Name=tag:Name,Values=app01" \
  --region "$AWS_REGION"

APP01_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=app01" Name=instance-state-name,Values=running \
  --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo ""
echo "==> app01 is up: $APP01_IP"
echo "    The Spring Boot app takes ~60s to start after the instance is running."
echo "    Check: ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@${APP01_IP}"
echo "           sudo journalctl -u selfapp -f"
echo "           curl localhost:8080/actuator/health"
echo ""
echo "    Run 06-alb.sh next."
