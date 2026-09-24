#!/usr/bin/env bash
# =============================================================================
# 06-alb.sh
# Creates the Application Load Balancer in front of the app tier:
#   Target group (HTTP :8080, health check /actuator/health)
#   → registers app01 (if it exists)
#   → internet-facing ALB across every default subnet (multi-AZ)
#   → listeners, reconciled to match config.sh on every run:
#       CERT_ARN set:   :443 HTTPS → app,  :80 → 301 redirect to HTTPS
#       CERT_ARN empty: :80  HTTP  → app  (and any :443 listener is removed)
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

SSL_POLICY="ELBSecurityPolicy-TLS13-1-2-2021-06"   # TLS 1.2 + 1.3 only

step "[06] Target group, ALB and listeners"

VPC_ID=$(get_vpc_id)
ELB_SG=$(get_sg_id "$ELB_SG_NAME")
[ -n "$ELB_SG" ] || die "Security group '$ELB_SG_NAME' not found — run 01-security-groups.sh first"

if [ -n "$CERT_ARN" ]; then
  CERT_STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
    --query 'Certificate.Status' --output text 2>/dev/null || echo "NOT_FOUND")
  [ "$CERT_STATUS" = "ISSUED" ] || die "Certificate $CERT_ARN is $CERT_STATUS (needs ISSUED, in $AWS_REGION)"
fi

# ---------- Target group ----------
TG_ARN=$(get_tg_arn)
if [ -z "$TG_ARN" ]; then
  log "Creating target group: $TG_NAME"
  TG_ARN=$(aws elbv2 create-target-group \
    --name "$TG_NAME" \
    --protocol HTTP --port 8080 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-path /actuator/health \
    --health-check-interval-seconds 15 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --tags "Key=Project,Value=$PROJECT_TAG" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
else
  log "Target group exists: $TG_NAME"
fi
# Default deregistration delay is 300s; 30s makes ASG rollouts much faster
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 > /dev/null

APP01_ID=$(get_instance_id app01)
if [ -n "$APP01_ID" ]; then
  log "Registering app01 ($APP01_ID)"
  aws elbv2 register-targets --target-group-arn "$TG_ARN" --targets "Id=$APP01_ID,Port=8080"
else
  log "No app01 instance — skipping registration (the ASG registers its own instances)"
fi

# ---------- Load balancer ----------
ALB_ARN=$(get_alb_arn)
if [ -z "$ALB_ARN" ]; then
  read -r -a SUBNETS <<<"$(get_default_subnets)"
  [ ${#SUBNETS[@]} -ge 2 ] || die "An ALB needs subnets in at least 2 AZs; found ${#SUBNETS[@]}"
  log "Creating ALB: $ALB_NAME (${#SUBNETS[@]} subnets)"
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --type application --scheme internet-facing \
    --subnets "${SUBNETS[@]}" \
    --security-groups "$ELB_SG" \
    --tags "Key=Project,Value=$PROJECT_TAG" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  log "Waiting for the ALB to become active (~2-3 min)..."
  aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
else
  log "ALB exists: $ALB_NAME"
fi
# Security best practice: drop requests with malformed HTTP headers
aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
  --attributes Key=routing.http.drop_invalid_header_fields.enabled,Value=true > /dev/null

# ---------- Listeners (create or update, never "may already exist") ----------
get_listener_arn() {  # $1 = port
  aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`$1\`].ListenerArn | [0]" --output text | none_to_empty
}

# $1 = port, $2 = protocol, $3 = default action, remaining = extra CLI args
ensure_listener() {
  local port=$1 protocol=$2 action=$3 arn; shift 3
  arn=$(get_listener_arn "$port")
  if [ -n "$arn" ]; then
    aws elbv2 modify-listener --listener-arn "$arn" \
      --protocol "$protocol" --port "$port" --default-actions "$action" "$@" > /dev/null
    log "Updated listener :$port ($protocol)"
  else
    aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
      --protocol "$protocol" --port "$port" --default-actions "$action" \
      --tags "Key=Project,Value=$PROJECT_TAG" "$@" > /dev/null
    log "Created listener :$port ($protocol)"
  fi
}

FORWARD="Type=forward,TargetGroupArn=$TG_ARN"
REDIRECT="Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}"

if [ -n "$CERT_ARN" ]; then
  ensure_listener 443 HTTPS "$FORWARD" \
    --certificates "CertificateArn=$CERT_ARN" --ssl-policy "$SSL_POLICY"
  ensure_listener 80 HTTP "$REDIRECT"
else
  ensure_listener 80 HTTP "$FORWARD"
  HTTPS_LISTENER=$(get_listener_arn 443)
  if [ -n "$HTTPS_LISTENER" ]; then
    aws elbv2 delete-listener --listener-arn "$HTTPS_LISTENER"
    log "Removed :443 listener (CERT_ARN is empty)"
  fi
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo ""
step "Done. ALB: http://$ALB_DNS"
if [ -n "$DOMAIN_NAME" ]; then
  log "In your DNS provider, point a CNAME for $DOMAIN_NAME → $ALB_DNS"
fi
log "Targets take ~30-60s to pass health checks once the app is up."
log "Next: 07-asg.sh"
