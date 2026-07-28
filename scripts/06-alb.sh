#!/usr/bin/env bash
# =============================================================================
# 06-alb.sh
# Creates: Target Group → registers app01 → ALB → Listeners (HTTP + HTTPS)
#
# If CERT_ARN is set in config.sh: HTTP redirects to HTTPS, HTTPS forwards.
# If CERT_ARN is empty:            HTTP forwards directly (no SSL, for testing).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

echo "==> [06] Creating ALB, Target Group, Listeners"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --region "$AWS_REGION" \
  --query 'Vpcs[0].VpcId' --output text)

ELB_SG=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=selfapp-ELB-sg Name=vpc-id,Values="$VPC_ID" \
  --region "$AWS_REGION" \
  --query 'SecurityGroups[0].GroupId' --output text)

# ---------- Target Group ----------
TG_ARN=$(aws elbv2 describe-target-groups \
  --names selfapp-tg \
  --region "$AWS_REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")

if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
  echo "  Creating target group: selfapp-tg (port 8080)"
  TG_ARN=$(aws elbv2 create-target-group \
    --name selfapp-tg \
    --protocol HTTP \
    --port 8080 \
    --vpc-id "$VPC_ID" \
    --health-check-path /actuator/health \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region "$AWS_REGION" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
else
  echo "  Target group already exists: $TG_ARN"
fi

# ---------- Register app01 ----------
APP01_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=app01" Name=instance-state-name,Values=running \
  --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

echo "  Registering app01 ($APP01_ID) in target group..."
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets Id="$APP01_ID",Port=8080 \
  --region "$AWS_REGION"

# ---------- Subnets (at least 2 AZs for ALB) ----------
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" Name=defaultForAz,Values=true \
  --region "$AWS_REGION" \
  --query 'Subnets[*].SubnetId' --output text | tr '\t' ' ')

# ---------- Create ALB ----------
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names selfapp-alb \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")

if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  echo "  Creating ALB: selfapp-alb"
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name selfapp-alb \
    --subnets $SUBNET_IDS \
    --security-groups "$ELB_SG" \
    --region "$AWS_REGION" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
else
  echo "  ALB already exists: $ALB_ARN"
fi

# ---------- Listeners ----------
if [ -n "$CERT_ARN" ]; then
  echo "  Adding HTTPS listener (443) with cert: $CERT_ARN"
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS --port 443 \
    --certificates CertificateArn="$CERT_ARN" \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --region "$AWS_REGION" 2>/dev/null || echo "  Listener may already exist"

  echo "  Adding HTTP→HTTPS redirect listener (80)"
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions \
      "Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}" \
    --region "$AWS_REGION" 2>/dev/null || echo "  Listener may already exist"
else
  echo "  No CERT_ARN set — adding plain HTTP listener (port 80 → app :8080)"
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --region "$AWS_REGION" 2>/dev/null || echo "  Listener may already exist"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo ""
echo "==> Done."
echo "    ALB DNS: $ALB_DNS"
if [ -n "$DOMAIN_NAME" ]; then
  echo "    Point a CNAME for $DOMAIN_NAME → $ALB_DNS in your DNS provider."
fi
echo ""
echo "    Run 07-asg.sh next, or validate now with 08-validate.sh."
