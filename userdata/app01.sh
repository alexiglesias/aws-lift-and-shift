#!/bin/bash
# =============================================================================
# app01 — selfapp-lite Spring Boot JAR (Java 17, systemd service)
# - JAR comes from S3, secrets from SSM Parameter Store (via the instance role)
# - db01 / rmq01 are reached by name through the Route 53 private zone
# - Config lives in a root-only EnvironmentFile, not in the unit file
# Used by both 05-deploy-app.sh (app01) and the ASG launch template (07).
# Log: /var/log/userdata-app01.log
# =============================================================================
set -euo pipefail
exec > /var/log/userdata-app01.log 2>&1
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

dnf -y upgrade
dnf -y install java-17-amazon-corretto-headless

# Service account with no login shell
id appuser &>/dev/null || useradd --system --shell /sbin/nologin appuser

# JAR: readable by the service account, writable by nobody
mkdir -p /opt/selfapp
aws s3 cp "s3://__BUCKET_NAME__/__JAR_KEY__" /opt/selfapp/selfapp.jar --region "__AWS_REGION__"
chown root:appuser /opt/selfapp/selfapp.jar
chmod 0440 /opt/selfapp/selfapp.jar

# Environment for Spring Boot (names match application.properties)
DB_PASS=$(get_secret db-pass)
RMQ_PASS=$(get_secret rmq-pass)
install -d -m 0700 /etc/selfapp
install -m 0600 /dev/null /etc/selfapp/selfapp.env
cat > /etc/selfapp/selfapp.env <<ENV
DB_HOST=db01.__PRIVATE_ZONE__
DB_PORT=3306
DB_NAME=__DB_NAME__
DB_USER=__DB_USER__
DB_PASS=${DB_PASS}
MQ_HOST=rmq01.__PRIVATE_ZONE__
MQ_PORT=5672
MQ_USER=__RMQ_USER__
MQ_PASS=${RMQ_PASS}
ENV

cat > /etc/systemd/system/selfapp.service <<'UNIT'
[Unit]
Description=selfapp-lite Spring Boot
Wants=network-online.target
After=network-online.target

[Service]
User=appuser
WorkingDirectory=/opt/selfapp
EnvironmentFile=/etc/selfapp/selfapp.env
# Cap the heap so the JVM fits comfortably in a 1 GiB instance
ExecStart=/usr/bin/java -XX:MaxRAMPercentage=60 -jar /opt/selfapp/selfapp.jar
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now selfapp

echo "app01 setup complete: selfapp-lite starting on :8080"
