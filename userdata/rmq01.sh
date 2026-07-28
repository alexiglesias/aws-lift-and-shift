#!/bin/bash
# =============================================================================
# rmq01 — RabbitMQ 3.13 with management plugin
# selfapp-lite doesn't wire RabbitMQ yet — kept as a stretch exercise.
# Management UI available on port 15672 (access via SSH tunnel for security).
# =============================================================================
set -euo pipefail
exec > /var/log/userdata-rmq01.log 2>&1

dnf update -y

# Install Erlang (RabbitMQ dependency)
dnf install -y https://github.com/rabbitmq/erlang-rpm/releases/download/v26.2.5/erlang-26.2.5-1.el9.x86_64.rpm || \
  dnf install -y erlang

# Install RabbitMQ
rpm --import https://www.rabbitmq.com/rabbitmq-signing-key-public.asc
dnf install -y https://github.com/rabbitmq/rabbitmq-server/releases/download/v3.13.3/rabbitmq-server-3.13.3-1.el8.noarch.rpm || \
  dnf install -y rabbitmq-server

systemctl enable --now rabbitmq-server

# Wait for RabbitMQ to be ready
for i in {1..30}; do
  rabbitmqctl status &>/dev/null && break
  echo "Waiting for RabbitMQ... ($i)"
  sleep 3
done

# Enable the management UI
rabbitmq-plugins enable rabbitmq_management

# Create an admin user (guest is localhost-only by default)
rabbitmqctl add_user admin adminpass
rabbitmqctl set_user_tags admin administrator
rabbitmqctl set_permissions -p / admin ".*" ".*" ".*"

echo "rmq01 setup complete. Management UI on :15672 (admin/adminpass)"
