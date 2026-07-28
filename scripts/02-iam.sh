#!/usr/bin/env bash
# =============================================================================
# 02-iam.sh
# Creates IAM Role + Instance Profile so app01 can pull from S3
# without hard-coded credentials.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

ROLE_NAME="selfapp-ec2-s3-role"
PROFILE_NAME="selfapp-ec2-profile"
TRUST_POLICY="$(dirname "$0")/../iam/ec2-trust.json"

echo "==> [02] Setting up IAM Role and Instance Profile"

# ---------- Role ----------
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "  Role '$ROLE_NAME' already exists — skipping creation"
else
  echo "  Creating role: $ROLE_NAME"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file://"$TRUST_POLICY"
fi

echo "  Attaching AmazonS3ReadOnlyAccess..."
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true

# ---------- Instance Profile ----------
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" &>/dev/null; then
  echo "  Instance profile '$PROFILE_NAME' already exists — skipping creation"
else
  echo "  Creating instance profile: $PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME"
fi

PROFILE_ARN=$(aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --query 'InstanceProfile.Arn' --output text)

echo ""
echo "==> Done."
echo "    Instance Profile ARN: $PROFILE_ARN"
