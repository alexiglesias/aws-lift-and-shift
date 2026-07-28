#!/usr/bin/env bash
# =============================================================================
# 08-validate.sh
# Runs a checklist to confirm the stack is healthy end-to-end.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

PASS="✅"
FAIL="❌"
WARN="⚠️ "

echo "==> [08] Validating selfapp Lift & Shift deployment"
echo ""

ERRORS=0

check() {
  local LABEL=$1 CMD=$2
  if eval "$CMD" &>/dev/null; then
    echo "  $PASS $LABEL"
  else
    echo "  $FAIL $LABEL"
    ERRORS=$((ERRORS + 1))
  fi
}

# ---------- EC2 instances running ----------
echo "--- EC2 Instances ---"
for NAME in db01 mc01 rmq01 app01; do
  STATE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" Name=instance-state-name,Values=running \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "none")
  if [ "$STATE" = "running" ]; then
    echo "  $PASS $NAME is running"
  else
    echo "  $FAIL $NAME is NOT running (state: $STATE)"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "--- ALB & Target Group ---"

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names selfapp-alb \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")

if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "None" ]; then
  echo "  $FAIL selfapp-alb not found"
  ERRORS=$((ERRORS + 1))
else
  echo "  $PASS selfapp-alb exists: $ALB_DNS"
fi

TG_ARN=$(aws elbv2 describe-target-groups \
  --names selfapp-tg \
  --region "$AWS_REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")

if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
  HEALTHY=$(aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --region "$AWS_REGION" \
    --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`] | length(@)' --output text)
  if [ "$HEALTHY" -gt 0 ]; then
    echo "  $PASS Target group: $HEALTHY healthy target(s)"
  else
    echo "  $WARN Target group: 0 healthy targets (app may still be starting)"
    echo "       Check: aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $AWS_REGION"
  fi
fi

echo ""
echo "--- App Health Check ---"

if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${ALB_DNS}/actuator/health" || echo "000")
  if [ "$HTTP_STATUS" = "200" ]; then
    echo "  $PASS /actuator/health → HTTP $HTTP_STATUS"
  else
    echo "  $WARN /actuator/health → HTTP $HTTP_STATUS (may still be starting, retry in ~60s)"
  fi

  HTTP_LOGIN=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${ALB_DNS}/login" || echo "000")
  if [ "$HTTP_LOGIN" = "200" ]; then
    echo "  $PASS /login → HTTP $HTTP_LOGIN"
  else
    echo "  $WARN /login → HTTP $HTTP_LOGIN"
  fi
fi

echo ""
echo "--- Route 53 ---"
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$PRIVATE_ZONE" \
  --query "HostedZones[?Name=='${PRIVATE_ZONE}.'].Id" \
  --output text 2>/dev/null | cut -d/ -f3)

if [ -n "$ZONE_ID" ]; then
  RECORD_COUNT=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --query 'ResourceRecordSets[?Type==`A`] | length(@)' --output text)
  echo "  $PASS Hosted zone $PRIVATE_ZONE exists ($RECORD_COUNT A records)"
else
  echo "  $FAIL Hosted zone $PRIVATE_ZONE not found"
  ERRORS=$((ERRORS + 1))
fi

echo ""
echo "--- ASG ---"
ASG_DESIRED=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names selfapp-asg \
  --region "$AWS_REGION" \
  --query 'AutoScalingGroups[0].DesiredCapacity' --output text 2>/dev/null || echo "0")
if [ "$ASG_DESIRED" -gt 0 ]; then
  echo "  $PASS selfapp-asg desired capacity: $ASG_DESIRED"
else
  echo "  $WARN selfapp-asg not found or has 0 desired capacity"
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "==> All checks passed!"
  echo ""
  echo "    Access the app:"
  [ -n "$ALB_DNS" ] && echo "    http://${ALB_DNS}/login"
  [ -n "$DOMAIN_NAME" ] && echo "    https://${DOMAIN_NAME}/login"
else
  echo "==> $ERRORS check(s) failed. Review output above."
fi
