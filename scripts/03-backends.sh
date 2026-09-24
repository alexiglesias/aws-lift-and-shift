#!/usr/bin/env bash
# =============================================================================
# 03-backends.sh
# Launches the backend tier — one EC2 instance per service, mirroring the
# docker-compose stack:
#   db01  → MySQL 8.4    (userdata/db01.sh)
#   rmq01 → RabbitMQ 3.13 (userdata/rmq01.sh)
# Both get the instance profile so they can read their passwords from SSM.
# Safe to re-run: instances that are already pending/running are skipped.
# =============================================================================
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
init_account

step "[03] Launching backend instances"

BACKEND_SG=$(get_sg_id "$BACKEND_SG_NAME")
[ -n "$BACKEND_SG" ] || die "Security group '$BACKEND_SG_NAME' not found — run 01-security-groups.sh first"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

INSTANCE_IDS=()
for NAME in db01 rmq01; do
  ID=$(get_instance_id "$NAME")
  if [ -n "$ID" ]; then
    log "$NAME already exists ($ID) — skipping"
  else
    render_template "$ROOT_DIR/userdata/$NAME.sh" > "$TMP_DIR/$NAME.sh"
    ID=$(launch_instance "$NAME" "$BACKEND_SG" "$TMP_DIR/$NAME.sh")
    log "Launched $NAME: $ID"
  fi
  INSTANCE_IDS+=("$ID")
done

# Wait on these exact IDs — filtering by tag would also match terminated
# instances from earlier runs and make the waiter fail.
log "Waiting for ${INSTANCE_IDS[*]} to reach 'running'..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}"

echo ""
step "Backends running:"
aws ec2 describe-instances --instance-ids "${INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value, InstanceId, PrivateIpAddress]' \
  --output text | while read -r N I IP; do log "$N  $I  $IP"; done

echo ""
log "'running' means booted, not ready: MySQL and RabbitMQ take ~3-5 min to install."
log "Follow progress with: ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@<public-ip> sudo tail -f /var/log/userdata-db01.log"
log "Next: 04-route53.sh"
