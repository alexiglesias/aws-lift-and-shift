#!/usr/bin/env bash
# =============================================================================
# lib.sh — shared helpers, sourced by every numbered script.
#   - loads and validates config.sh (fails fast with a clear message)
#   - defines resource names in ONE place
#   - wraps common AWS lookups so each script stays short
# Not meant to be executed directly.
# =============================================================================
# Constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SELFAPP_CONFIG lets tests point at a throwaway config instead of config.sh
CONFIG_FILE="${SELFAPP_CONFIG:-$ROOT_DIR/config.sh}"

# ---------- Logging ----------
step() { echo "==> $*"; }
log()  { echo "  $*"; }
warn() { echo "  WARNING: $*" >&2; }
die()  { echo "  ERROR: $*" >&2; exit 1; }

# ---------- Load config ----------
[ -f "$CONFIG_FILE" ] || die "$CONFIG_FILE not found. Run: cp config.sh.example config.sh"
# shellcheck source=../config.sh.example disable=SC1091
source "$CONFIG_FILE"

# Defaults for optional settings
: "${INSTANCE_TYPE:=t2.micro}"
: "${PROJECT_TAG:=selfapp-lift-shift}"
: "${SSM_PREFIX:=/selfapp}"
: "${PRIVATE_ZONE:=selfapp.internal}"
: "${DOMAIN_NAME:=}"
: "${CERT_ARN:=}"
: "${BUCKET_NAME:=}"

# AWS CLI: use the configured region everywhere and never open a pager
# (a pager would block the scripts waiting for keyboard input).
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

# ---------- Resource names (single source of truth) ----------
ELB_SG_NAME="selfapp-elb-sg"
APP_SG_NAME="selfapp-app-sg"
BACKEND_SG_NAME="selfapp-backend-sg"
ROLE_NAME="selfapp-ec2-role"
PROFILE_NAME="selfapp-ec2-profile"
TG_NAME="selfapp-tg"
ALB_NAME="selfapp-alb"
LT_NAME="selfapp-lt"
ASG_NAME="selfapp-asg"
JAR_KEY="selfapp-lite.jar"

# ---------- Validation ----------
require_vars() {
  local missing=() var
  for var in "$@"; do
    [ -n "${!var:-}" ] || missing+=("$var")
  done
  [ ${#missing[@]} -eq 0 ] || die "Set these in config.sh: ${missing[*]}"
}

# Values that get substituted into templates must be plain identifiers.
check_safe_name() {
  local var=$1
  [[ "${!var}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "$var='${!var}' may only contain letters, digits, '.', '_' and '-'"
}

# Passwords end up in SQL, systemd EnvironmentFiles and CLI arguments,
# so restrict them to characters that are safe in all three.
check_password() {
  local var=$1
  [[ "${!var}" =~ ^[A-Za-z0-9._@%+=:,-]{12,}$ ]] \
    || die "$var must be 12+ characters from [A-Za-z0-9._@%+=:,-]. Generate one with: openssl rand -base64 24 | tr -d '/+='"
}

validate_config() {
  require_vars AWS_REGION AMI_ID KEY_NAME YOUR_IP DB_NAME DB_USER DB_PASS DB_ROOT_PASS RMQ_USER RMQ_PASS APP_SRC_DIR
  [[ "$YOUR_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "YOUR_IP='$YOUR_IP' is not an IPv4 address. Find yours with: curl -s https://checkip.amazonaws.com"
  local v
  for v in AWS_REGION KEY_NAME DB_NAME DB_USER RMQ_USER PRIVATE_ZONE INSTANCE_TYPE PROJECT_TAG; do
    check_safe_name "$v"
  done
  [[ "$SSM_PREFIX" =~ ^/[A-Za-z0-9._/-]+[A-Za-z0-9._-]$ ]] || die "SSM_PREFIX must look like /selfapp"
  for v in DB_PASS DB_ROOT_PASS RMQ_PASS; do
    check_password "$v"
  done
  [ -z "$BUCKET_NAME" ] || [[ "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
    || die "BUCKET_NAME='$BUCKET_NAME' is not a valid S3 bucket name"
}

validate_config

# ---------- Account-derived values ----------
# Call init_account in scripts that need ACCOUNT_ID or BUCKET_NAME.
init_account() {
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
    || die "AWS CLI is not authenticated. Run: aws configure"
  [ -n "$BUCKET_NAME" ] || BUCKET_NAME="selfapp-artifacts-${ACCOUNT_ID}"
  export ACCOUNT_ID BUCKET_NAME
}

# ---------- Lookups (print the ID, or an empty string if not found) ----------
none_to_empty() { local v; v=$(cat); [ "$v" = "None" ] && v=""; echo "$v"; }

get_vpc_id() {
  aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text | none_to_empty
}

get_sg_id() {  # $1 = security group name
  aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$1" Name=vpc-id,Values="$(get_vpc_id)" \
    --query 'SecurityGroups[0].GroupId' --output text | none_to_empty
}

get_instance_id() {  # $1 = Name tag; only pending/running instances count
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJECT_TAG" \
              Name=instance-state-name,Values=pending,running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text | none_to_empty
}

get_profile_arn() {
  aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --query 'InstanceProfile.Arn' --output text 2>/dev/null | none_to_empty
}

get_default_subnets() {  # space-separated subnet IDs, one per AZ
  aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$(get_vpc_id)" Name=defaultForAz,Values=true \
    --query 'Subnets[*].SubnetId' --output text | tr '\t' ' '
}

# ---------- Security group rules ----------
# Adds an ingress rule; "already exists" is fine, any other error is fatal.
authorize_ingress() {  # $1 = sg-id, remaining args passed to the CLI
  local sg=$1 out; shift
  if ! out=$(aws ec2 authorize-security-group-ingress --group-id "$sg" "$@" 2>&1); then
    grep -q 'InvalidPermission.Duplicate' <<<"$out" && return 0
    die "Failed to add ingress rule to $sg: $out"
  fi
}

# ---------- Templates ----------
# Replaces __PLACEHOLDER__ tokens with validated, non-secret config values.
# Secrets are never rendered into templates; instances read them from SSM.
render_template() {  # $1 = source file, stdout = rendered content
  sed \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    -e "s|__ACCOUNT_ID__|${ACCOUNT_ID:-}|g" \
    -e "s|__BUCKET_NAME__|${BUCKET_NAME:-}|g" \
    -e "s|__JAR_KEY__|${JAR_KEY}|g" \
    -e "s|__PRIVATE_ZONE__|${PRIVATE_ZONE}|g" \
    -e "s|__SSM_PREFIX__|${SSM_PREFIX}|g" \
    -e "s|__DB_NAME__|${DB_NAME}|g" \
    -e "s|__DB_USER__|${DB_USER}|g" \
    -e "s|__RMQ_USER__|${RMQ_USER}|g" \
    "$1"
}

get_private_ip() {  # $1 = Name tag
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=$PROJECT_TAG" \
              Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text | none_to_empty
}

# ---------- Launching instances ----------
# Launches one tagged instance with the project's standard settings and
# prints its ID:
#   - instance profile (S3 + SSM read), IMDSv2 required
#   - burstable CPU credits in "standard" mode, so a t3 can't run up
#     "unlimited" surplus-credit charges
#   - Name/Project tags on the instance AND its EBS volume
# Retries briefly: EC2 can reject a brand-new instance profile for a few
# seconds while IAM propagates.
launch_instance() {  # $1 = Name tag, $2 = security group ID, $3 = user-data file
  local name=$1 sg=$2 userdata=$3 profile_arn out attempt
  local credit=()
  profile_arn=$(get_profile_arn)
  [ -n "$profile_arn" ] || die "Instance profile '$PROFILE_NAME' not found — run 02-iam.sh first"
  [[ "$INSTANCE_TYPE" == t* ]] && credit=(--credit-specification CpuCredits=standard)

  for attempt in 1 2 3 4 5; do
    # ${credit[@]+"${credit[@]}"}: safe empty-array expansion on macOS Bash 3.2
    if out=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$sg" \
        --iam-instance-profile "Arn=$profile_arn" \
        --metadata-options HttpTokens=required,HttpEndpoint=enabled \
        ${credit[@]+"${credit[@]}"} \
        --user-data "file://$userdata" \
        --tag-specifications \
          "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Project,Value=$PROJECT_TAG}]" \
          "ResourceType=volume,Tags=[{Key=Name,Value=$name},{Key=Project,Value=$PROJECT_TAG}]" \
        --query 'Instances[0].InstanceId' --output text 2>&1); then
      echo "$out"
      return 0
    fi
    grep -q 'iamInstanceProfile' <<<"$out" || die "run-instances failed for $name: $out"
    warn "Instance profile not ready yet (attempt $attempt/5), retrying in 10s..."
    sleep 10
  done
  die "Could not launch $name: $out"
}

# describe-* by name returns an error (not "None") when nothing exists,
# so these swallow that specific case and print an empty string.
get_tg_arn() {
  aws elbv2 describe-target-groups --names "$TG_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | none_to_empty || true
}

get_alb_arn() {
  aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | none_to_empty || true
}

asg_exists() {
  [ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME" \
    --query 'length(AutoScalingGroups)' --output text)" != "0" ]
}
