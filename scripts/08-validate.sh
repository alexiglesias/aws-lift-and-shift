#!/usr/bin/env bash
# =============================================================================
# 08-validate.sh
# End-to-end checklist for the deployment. Exits 0 only if every check
# passes, so it can gate a CI pipeline or a teardown/redeploy script.
#
#   ✅ pass   ❌ fail (counts toward the exit code)   ⚠️  warning (informational)
#
# Usage:
#   bash scripts/08-validate.sh          # check once
#   bash scripts/08-validate.sh --wait   # first wait up to 10 min for healthy
#                                        # targets (handy right after deploying)
# =============================================================================
# No "set -e": every check must run even when an earlier one fails.
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

WAIT=false
case "${1:-}" in
  --wait) WAIT=true ;;
  "") ;;
  *) die "Unknown option '$1'. Usage: $0 [--wait]" ;;
esac

FAILS=0 WARNS=0
pass()  { echo "  ✅ $*"; }
fail()  { echo "  ❌ $*"; FAILS=$((FAILS + 1)); }
warnc() { echo "  ⚠️  $*"; WARNS=$((WARNS + 1)); }
section() { echo ""; echo "--- $* ---"; }

step "[08] Validating the selfapp deployment in $AWS_REGION"

# ---------- Instances ----------
section "EC2 instances"
for NAME in db01 rmq01; do
  ID=$(get_instance_id "$NAME")
  if [ -n "$ID" ]; then pass "$NAME is running ($ID)"; else fail "$NAME is not running"; fi
done

if asg_exists; then
  read -r DESIRED IN_SERVICE <<<"$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].[DesiredCapacity, length(Instances[?LifecycleState==`InService`])]' \
    --output text)"
  if [ "$IN_SERVICE" -ge 1 ]; then
    pass "$ASG_NAME: $IN_SERVICE/$DESIRED instance(s) InService"
  else
    fail "$ASG_NAME: 0/$DESIRED instances InService"
  fi
  [ -z "$(get_instance_id app01)" ] || warnc "app01 is still running alongside the ASG — terminate it to save Free Tier hours"
else
  if [ -n "$(get_instance_id app01)" ]; then
    pass "app01 is running (no ASG yet — run 07-asg.sh)"
  else
    fail "No app tier: neither $ASG_NAME nor app01 exists"
  fi
fi

# ---------- Private DNS (also detects drift: record IP ≠ instance IP) ----------
section "Route 53 private zone"
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$PRIVATE_ZONE" \
  --query "HostedZones[?Name=='${PRIVATE_ZONE}.' && Config.PrivateZone] | [0].Id" \
  --output text | none_to_empty)
ZONE_ID=${ZONE_ID##*/}
if [ -z "$ZONE_ID" ]; then
  fail "Private zone $PRIVATE_ZONE not found"
else
  pass "Private zone $PRIVATE_ZONE exists ($ZONE_ID)"
  for HOST in db01 rmq01; do
    RECORD_IP=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${HOST}.${PRIVATE_ZONE}.' && Type=='A'].ResourceRecords[0].Value | [0]" \
      --output text | none_to_empty)
    ACTUAL_IP=$(get_private_ip "$HOST")
    if [ -z "$RECORD_IP" ]; then
      fail "${HOST}.${PRIVATE_ZONE} has no A record"
    elif [ "$RECORD_IP" != "$ACTUAL_IP" ]; then
      fail "${HOST}.${PRIVATE_ZONE} → $RECORD_IP but $HOST is at ${ACTUAL_IP:-<not running>} (re-run 04-route53.sh)"
    else
      pass "${HOST}.${PRIVATE_ZONE} → $RECORD_IP"
    fi
  done
fi

# ---------- Security groups: nothing but the ALB open to the world ----------
section "Security groups"
for SG_NAME in "$APP_SG_NAME" "$BACKEND_SG_NAME"; do
  SG_ID=$(get_sg_id "$SG_NAME")
  if [ -z "$SG_ID" ]; then fail "$SG_NAME not found"; continue; fi
  OPEN=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
    --query "SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0']] | length(@)" --output text)
  if [ "$OPEN" = "0" ]; then
    pass "$SG_NAME has no rules open to 0.0.0.0/0"
  else
    fail "$SG_NAME has $OPEN rule(s) open to 0.0.0.0/0"
  fi
done

# ---------- Load balancer + target health ----------
section "Load balancer"
ALB_ARN=$(get_alb_arn)
TG_ARN=$(get_tg_arn)
ALB_DNS=""
if [ -z "$ALB_ARN" ]; then
  fail "$ALB_NAME not found"
else
  read -r ALB_STATE ALB_DNS <<<"$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].[State.Code, DNSName]' --output text)"
  if [ "$ALB_STATE" = "active" ]; then pass "$ALB_NAME is active: $ALB_DNS"; else fail "$ALB_NAME state: $ALB_STATE"; fi
fi

healthy_count() {
  aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text
}

if [ -z "$TG_ARN" ]; then
  fail "$TG_NAME not found"
else
  if [ "$WAIT" = true ]; then
    log "Waiting up to 10 min for a healthy target..."
    for _ in $(seq 1 40); do
      [ "$(healthy_count)" -ge 1 ] && break
      sleep 15
    done
  fi
  HEALTHY=$(healthy_count)
  if [ "$HEALTHY" -ge 1 ]; then
    pass "$TG_NAME: $HEALTHY healthy target(s)"
  else
    fail "$TG_NAME: no healthy targets. Details:"
    aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State, TargetHealth.Description]' \
      --output text | while read -r LINE; do echo "       $LINE"; done
  fi
fi

# ---------- The app, through the public entrypoint ----------
section "Application (through the ALB)"
http_code() {  # $1 = URL; prints the status code, "000" if unreachable
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" || true
}

if [ -z "$ALB_DNS" ]; then
  fail "Skipped: no ALB DNS name"
else
  if [ -n "$CERT_ARN" ] && [ -n "$DOMAIN_NAME" ]; then
    BASE_URL="https://$DOMAIN_NAME"
    CODE=$(http_code "http://$ALB_DNS/login")
    if [ "$CODE" = "301" ]; then pass "HTTP → HTTPS redirect (301)"; else fail "HTTP returned $CODE, expected 301 redirect"; fi
  else
    BASE_URL="http://$ALB_DNS"
    [ -z "$CERT_ARN" ] && warnc "Serving plain HTTP (no CERT_ARN set)"
  fi

  HEALTH_BODY=$(curl -s --max-time 10 "$BASE_URL/actuator/health" || true)
  if grep -q '"status":"UP"' <<<"$HEALTH_BODY"; then
    pass "$BASE_URL/actuator/health → UP (MySQL + RabbitMQ reachable)"
  else
    fail "$BASE_URL/actuator/health → ${HEALTH_BODY:-no response}"
  fi

  CODE=$(http_code "$BASE_URL/login")
  if [ "$CODE" = "200" ]; then pass "$BASE_URL/login → 200"; else fail "$BASE_URL/login → $CODE"; fi
fi

# ---------- Cost awareness ----------
section "Cost"
RUNNING=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" Name=instance-state-name,Values=running \
  --query 'length(Reservations[].Instances[])' --output text)
warnc "$RUNNING instance(s) running ≈ $((RUNNING * 24)) instance-hours/day. Run 99-teardown.sh when you're done."

# ---------- Result ----------
echo ""
if [ "$FAILS" -eq 0 ]; then
  step "All checks passed ($WARNS warning(s)). Open: ${BASE_URL:-http://$ALB_DNS}/login"
  exit 0
else
  step "$FAILS check(s) failed, $WARNS warning(s). See ❌ above."
  exit 1
fi
