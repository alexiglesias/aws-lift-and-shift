#!/bin/bash
# =============================================================================
# rmq01 — RabbitMQ 3.13 (same major version as the docker-compose stack)
# Pinned RPMs from the official GitHub releases, verified by SHA-256.
# The app publishes user.created events here (MQ_HOST in app01).
# Management UI (15672) is NOT exposed — use an SSH tunnel.
# Log: /var/log/userdata-rmq01.log
# =============================================================================
set -euo pipefail
exec > /var/log/userdata-rmq01.log 2>&1
trap 'echo "FAILED at line $LINENO"' ERR

get_secret() {
  local _
  for _ in {1..10}; do
    aws ssm get-parameter --region "__AWS_REGION__" --name "__SSM_PREFIX__/$1" \
      --with-decryption --query Parameter.Value --output text && return 0
    sleep 5
  done
  return 1
}

ERLANG_URL="https://github.com/rabbitmq/erlang-rpm/releases/download/v26.2.5.6/erlang-26.2.5.6-1.el9.x86_64.rpm"
ERLANG_SHA256="534f96a0b3b124260baabf7061b7e15c6a5f3ad71f3ce37b24b43ce1e0dc2800"
RABBIT_URL="https://github.com/rabbitmq/rabbitmq-server/releases/download/v3.13.7/rabbitmq-server-3.13.7-1.el8.noarch.rpm"
RABBIT_SHA256="b132f30991318e893fb17d21bf614aa08baba859e3cf813faaa0f59c2606ec6e"

dnf -y upgrade

cd /tmp
curl -fsSL -o erlang.rpm   "$ERLANG_URL"
curl -fsSL -o rabbitmq.rpm "$RABBIT_URL"
echo "$ERLANG_SHA256  erlang.rpm"   | sha256sum -c -
echo "$RABBIT_SHA256  rabbitmq.rpm" | sha256sum -c -
dnf -y install ./erlang.rpm ./rabbitmq.rpm
rm -f erlang.rpm rabbitmq.rpm

systemctl enable --now rabbitmq-server

for i in {1..30}; do
  rabbitmq-diagnostics -q ping && break
  echo "Waiting for RabbitMQ... ($i)"; sleep 3
done

rabbitmq-plugins enable rabbitmq_management

# App user from config; remove the default guest account
RMQ_PASS=$(get_secret rmq-pass)
rabbitmqctl add_user "__RMQ_USER__" "$RMQ_PASS"
rabbitmqctl set_user_tags "__RMQ_USER__" administrator
rabbitmqctl set_permissions -p / "__RMQ_USER__" ".*" ".*" ".*"
rabbitmqctl delete_user guest

echo "rmq01 setup complete: AMQP on :5672, management UI on localhost:15672"
