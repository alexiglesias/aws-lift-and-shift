#!/usr/bin/env bash
# =============================================================================
# 07-asg.sh
# Creates a Launch Template from the current app01 config and attaches an
# Auto Scaling Group (min 1, max 3) to the selfapp-tg target group.
# CPU target tracking at 70% — scales out on sustained load.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

USERDATA_DIR="$(dirname "$0")/../userdata"

echo "==> [07] Creating Launch Template and Auto Scaling Group"

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

TG_ARN=$(aws elbv2 describe-target-groups \
  --names selfapp-tg \
  --region "$AWS_REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Resolve bucket name (same logic as 05-deploy-app.sh)
if [ -z "$BUCKET_NAME" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  BUCKET_NAME="selfapp-artifacts-${ACCOUNT_ID}"
fi

# ---------- Render userdata ----------
APP01_SCRIPT=$(mktemp)
sed \
  -e "s/__BUCKET_NAME__/${BUCKET_NAME}/g" \
  -e "s/__PRIVATE_ZONE__/${PRIVATE_ZONE}/g" \
  -e "s/__DB_NAME__/${DB_NAME}/g" \
  -e "s/__DB_USER__/${DB_USER}/g" \
  -e "s/__DB_PASS__/${DB_PASS}/g" \
  "$USERDATA_DIR/app01.sh" > "$APP01_SCRIPT"

USERDATA_B64=$(base64 -i "$APP01_SCRIPT")
rm -f "$APP01_SCRIPT"

# ---------- Launch Template ----------
LT_EXISTS=$(aws ec2 describe-launch-templates \
  --launch-template-names selfapp-lt \
  --region "$AWS_REGION" \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || echo "None")

if [ "$LT_EXISTS" = "None" ] || [ -z "$LT_EXISTS" ]; then
  echo "  Creating launch template: selfapp-lt"
  aws ec2 create-launch-template \
    --launch-template-name selfapp-lt \
    --region "$AWS_REGION" \
    --launch-template-data "{
      \"ImageId\": \"${AMI_ID}\",
      \"InstanceType\": \"t2.micro\",
      \"KeyName\": \"${KEY_NAME}\",
      \"SecurityGroupIds\": [\"${APP_SG}\"],
      \"IamInstanceProfile\": {\"Arn\": \"${PROFILE_ARN}\"},
      \"UserData\": \"${USERDATA_B64}\",
      \"TagSpecifications\": [{
        \"ResourceType\": \"instance\",
        \"Tags\": [{\"Key\":\"Name\",\"Value\":\"app01-asg\"},{\"Key\":\"Project\",\"Value\":\"selfapp-lift-shift\"}]
      }]
    }"
else
  echo "  Launch template already exists — skipping"
fi

# ---------- Subnet list for ASG ----------
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=defaultForAz,Values=true \
  --region "$AWS_REGION" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')

# ---------- Auto Scaling Group ----------
ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names selfapp-asg \
  --region "$AWS_REGION" \
  --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null || echo "None")

if [ "$ASG_EXISTS" = "None" ] || [ -z "$ASG_EXISTS" ]; then
  echo "  Creating Auto Scaling Group: selfapp-asg"
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name selfapp-asg \
    --launch-template LaunchTemplateName=selfapp-lt,Version='$Latest' \
    --min-size 1 --max-size 3 --desired-capacity 1 \
    --target-group-arns "$TG_ARN" \
    --vpc-zone-identifier "$SUBNET_IDS" \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --region "$AWS_REGION"
else
  echo "  ASG already exists — skipping"
fi

# ---------- Scaling Policy ----------
echo "  Attaching CPU target tracking policy (target: 70%)..."
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name selfapp-asg \
  --policy-name selfapp-scale-cpu \
  --policy-type TargetTrackingScaling \
  --region "$AWS_REGION" \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "TargetValue": 70.0
  }' > /dev/null

echo ""
echo "==> Done. ASG 'selfapp-asg' created (min=1, max=3, target CPU=70%)"
echo "    The manually launched app01 can now be terminated — the ASG replaces it."
echo ""
echo "    Run 08-validate.sh to confirm everything is working."
