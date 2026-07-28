#!/usr/bin/env bash
# =============================================================================
# 01-security-groups.sh
# Creates: Key Pair + 3 Security Groups (ELB, app, backend)
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

echo "==> [01] Creating Key Pair and Security Groups"

# ---------- Key Pair ----------
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &>/dev/null; then
  echo "  Creating key pair: $KEY_NAME"
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --region "$AWS_REGION" \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/"${KEY_NAME}".pem
  chmod 400 ~/.ssh/"${KEY_NAME}".pem
  echo "  Key saved to ~/.ssh/${KEY_NAME}.pem"
else
  echo "  Key pair '$KEY_NAME' already exists — skipping"
fi

# ---------- Get default VPC ----------
VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --region "$AWS_REGION" \
  --query 'Vpcs[0].VpcId' --output text)
echo "  VPC: $VPC_ID"

# Helper: create SG or return existing ID
create_sg() {
  local NAME=$1 DESC=$2
  local EXISTING
  EXISTING=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$NAME" Name=vpc-id,Values="$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
  if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
    echo "$EXISTING"
  else
    aws ec2 create-security-group \
      --group-name "$NAME" \
      --description "$DESC" \
      --vpc-id "$VPC_ID" \
      --region "$AWS_REGION" \
      --query 'GroupId' --output text
  fi
}

# ---------- selfapp-ELB-sg ----------
echo "  Creating selfapp-ELB-sg..."
ELB_SG=$(create_sg "selfapp-ELB-sg" "ALB public traffic")
aws ec2 authorize-security-group-ingress --group-id "$ELB_SG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id "$ELB_SG" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null || true

# ---------- selfapp-app-sg ----------
echo "  Creating selfapp-app-sg..."
APP_SG=$(create_sg "selfapp-app-sg" "App EC2 - Spring Boot :8080")
aws ec2 authorize-security-group-ingress --group-id "$APP_SG" \
  --protocol tcp --port 8080 --source-group "$ELB_SG" --region "$AWS_REGION" 2>/dev/null || true
if [ "$YOUR_IP" != "0.0.0.0" ]; then
  aws ec2 authorize-security-group-ingress --group-id "$APP_SG" \
    --protocol tcp --port 22 --cidr "${YOUR_IP}/32" --region "$AWS_REGION" 2>/dev/null || true
fi

# ---------- selfapp-backend-sg ----------
echo "  Creating selfapp-backend-sg..."
BACKEND_SG=$(create_sg "selfapp-backend-sg" "Backend services - MySQL, Memcached, RabbitMQ")
# Allow app EC2 → backend ports
for PORT in 3306 11211 5672 15672; do
  aws ec2 authorize-security-group-ingress --group-id "$BACKEND_SG" \
    --protocol tcp --port "$PORT" --source-group "$APP_SG" --region "$AWS_REGION" 2>/dev/null || true
done
# Allow backend instances to reach each other
aws ec2 authorize-security-group-ingress --group-id "$BACKEND_SG" \
  --protocol all --source-group "$BACKEND_SG" --region "$AWS_REGION" 2>/dev/null || true
if [ "$YOUR_IP" != "0.0.0.0" ]; then
  aws ec2 authorize-security-group-ingress --group-id "$BACKEND_SG" \
    --protocol tcp --port 22 --cidr "${YOUR_IP}/32" --region "$AWS_REGION" 2>/dev/null || true
fi

echo ""
echo "==> Done. Security Group IDs:"
echo "    ELB_SG:     $ELB_SG"
echo "    APP_SG:     $APP_SG"
echo "    BACKEND_SG: $BACKEND_SG"
echo ""
echo "    These are auto-discovered by subsequent scripts."
