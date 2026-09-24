#!/usr/bin/env bash
# =============================================================================
# 02-iam.sh
# 1. Stores app secrets in SSM Parameter Store (SecureString, free tier)
# 2. Creates an IAM role + instance profile that can ONLY:
#      - read objects from the artifact bucket
#      - read parameters under SSM_PREFIX
# Instances get temporary credentials from the role — no access keys anywhere.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
init_account

TRUST_POLICY="$ROOT_DIR/iam/ec2-trust.json"
PERMISSIONS_TEMPLATE="$ROOT_DIR/iam/ec2-permissions.json"

step "[02] Secrets, IAM role and instance profile"

# ---------- Secrets → SSM Parameter Store ----------
# --overwrite keeps AWS in sync with config.sh on every run.
put_secret() {  # $1 = parameter name (under SSM_PREFIX), $2 = value
  aws ssm put-parameter \
    --name "${SSM_PREFIX}/$1" --value "$2" \
    --type SecureString --overwrite > /dev/null
  log "Stored ${SSM_PREFIX}/$1"
}
put_secret db-pass      "$DB_PASS"
put_secret db-root-pass "$DB_ROOT_PASS"
put_secret rmq-pass     "$RMQ_PASS"

# ---------- Role ----------
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  log "Role '$ROLE_NAME' already exists"
else
  log "Creating role: $ROLE_NAME"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY" \
    --tags "Key=Project,Value=$PROJECT_TAG" > /dev/null
fi

# Inline least-privilege policy, re-applied every run so it tracks config.sh
POLICY_FILE=$(mktemp)
trap 'rm -f "$POLICY_FILE"' EXIT
render_template "$PERMISSIONS_TEMPLATE" > "$POLICY_FILE"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name selfapp-least-privilege \
  --policy-document "file://$POLICY_FILE"
log "Applied inline policy: S3 read on $BUCKET_NAME, SSM read on ${SSM_PREFIX}/*"

# ---------- Instance profile ----------
NEW_PROFILE=false
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" &>/dev/null; then
  log "Instance profile '$PROFILE_NAME' already exists"
else
  log "Creating instance profile: $PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --tags "Key=Project,Value=$PROJECT_TAG" > /dev/null
  aws iam wait instance-profile-exists --instance-profile-name "$PROFILE_NAME"
  NEW_PROFILE=true
fi

# Attach the role if it isn't already (also repairs a half-finished earlier run)
ATTACHED=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
  --query "InstanceProfile.Roles[?RoleName=='$ROLE_NAME'] | length(@)" --output text)
if [ "$ATTACHED" = "0" ]; then
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
  NEW_PROFILE=true
fi

# IAM is eventually consistent: EC2 can reject a brand-new profile for a few
# seconds ("Invalid IAM Instance Profile"). Pause once so step 03 doesn't fail.
if [ "$NEW_PROFILE" = true ]; then
  log "Waiting 15s for IAM to propagate..."
  sleep 15
fi

echo ""
step "Done. Instance profile: $(get_profile_arn)"
