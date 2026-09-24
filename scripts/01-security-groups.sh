#!/usr/bin/env bash
# =============================================================================
# 01-security-groups.sh
# Creates: SSH key pair + 3 security groups, chained so each tier only
# accepts traffic from the tier in front of it:
#
#   Internet --80/443--> elb-sg --8080--> app-sg --3306/5672--> backend-sg
#
# SSH (22) is allowed only from YOUR_IP.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

step "[01] Key pair and security groups"

# ---------- Key pair ----------
PEM_FILE="$HOME/.ssh/${KEY_NAME}.pem"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
  log "Key pair '$KEY_NAME' already exists — skipping"
  [ -f "$PEM_FILE" ] || warn "$PEM_FILE is missing; you won't be able to SSH. Delete the key pair in AWS and re-run to recreate it."
else
  # An empty file is debris from an earlier failed run — safe to remove.
  [ -s "$PEM_FILE" ] || rm -f "$PEM_FILE"
  [ ! -e "$PEM_FILE" ] || die "$PEM_FILE already exists but the key pair is not in AWS. Move the file away and re-run."
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  log "Creating key pair: $KEY_NAME"
  # Write to a temp file and move it into place only on success: a plain
  # "> $PEM_FILE" redirect would leave an empty key file if the call failed.
  PEM_TMP=$(mktemp "$HOME/.ssh/.${KEY_NAME}.XXXXXX")
  trap 'rm -f "$PEM_TMP"' EXIT
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
    --query 'KeyMaterial' --output text > "$PEM_TMP"
  chmod 400 "$PEM_TMP"
  mv "$PEM_TMP" "$PEM_FILE"
  log "Private key saved to $PEM_FILE"
fi

# ---------- Security groups ----------
VPC_ID=$(get_vpc_id)
[ -n "$VPC_ID" ] || die "No default VPC in $AWS_REGION. Create one with: aws ec2 create-default-vpc"
log "Default VPC: $VPC_ID"

ensure_sg() {  # $1 = name, $2 = description → prints the group ID
  local id
  id=$(get_sg_id "$1")
  if [ -z "$id" ]; then
    id=$(aws ec2 create-security-group \
      --group-name "$1" --description "$2" --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$1},{Key=Project,Value=$PROJECT_TAG}]" \
      --query 'GroupId' --output text)
  fi
  echo "$id"
}

ELB_SG=$(ensure_sg "$ELB_SG_NAME" "selfapp ALB - public HTTP/HTTPS")
log "$ELB_SG_NAME: $ELB_SG"
authorize_ingress "$ELB_SG" --protocol tcp --port 80  --cidr 0.0.0.0/0
authorize_ingress "$ELB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0

APP_SG=$(ensure_sg "$APP_SG_NAME" "selfapp app tier - Spring Boot 8080 from ALB")
log "$APP_SG_NAME: $APP_SG"
authorize_ingress "$APP_SG" --protocol tcp --port 8080 --source-group "$ELB_SG"
authorize_ingress "$APP_SG" --protocol tcp --port 22   --cidr "${YOUR_IP}/32"

BACKEND_SG=$(ensure_sg "$BACKEND_SG_NAME" "selfapp backends - MySQL and RabbitMQ from app tier")
log "$BACKEND_SG_NAME: $BACKEND_SG"
for PORT in 3306 5672; do   # MySQL, AMQP (RabbitMQ)
  authorize_ingress "$BACKEND_SG" --protocol tcp --port "$PORT" --source-group "$APP_SG"
done
authorize_ingress "$BACKEND_SG" --protocol tcp --port 22 --cidr "${YOUR_IP}/32"
# RabbitMQ management UI (15672) is intentionally NOT opened.
# Reach it through an SSH tunnel:
#   ssh -i ~/.ssh/selfapp-key.pem -L 15672:localhost:15672 ec2-user@<rmq01-public-ip>

echo ""
step "Done. Security groups are looked up by name in later scripts."
