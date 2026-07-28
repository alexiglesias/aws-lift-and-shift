#!/bin/bash
# =============================================================================
# app01 — selfapp-lite Spring Boot JAR
# Downloads the JAR from S3 (via IAM role — no hard-coded credentials).
# DB_HOST resolves via Route 53 private hosted zone (selfapp.internal).
# All __PLACEHOLDER__ values are substituted by 05-deploy-app.sh before
# this script is uploaded to EC2.
# =============================================================================
set -euo pipefail
exec > /var/log/userdata-app01.log 2>&1

dnf update -y
dnf install -y java-17-amazon-corretto

# Derive S3 bucket from account ID (same logic as 05-deploy-app.sh)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="__BUCKET_NAME__"
if [ -z "$BUCKET" ]; then
  BUCKET="selfapp-artifacts-${ACCOUNT_ID}"
fi

# Create app directory and user
mkdir -p /opt/selfapp
useradd -r -u 1001 appuser 2>/dev/null || true

# Download JAR from S3
aws s3 cp "s3://${BUCKET}/selfapp-lite-1.0.0.jar" /opt/selfapp/selfapp.jar
chown appuser:appuser /opt/selfapp/selfapp.jar
chmod 500 /opt/selfapp/selfapp.jar

# Create systemd service
cat > /etc/systemd/system/selfapp.service <<'UNIT'
[Unit]
Description=selfapp-lite Spring Boot
After=network.target

[Service]
User=appuser
WorkingDirectory=/opt/selfapp
ExecStart=/usr/bin/java -jar /opt/selfapp/selfapp.jar
Environment="DB_HOST=db01.__PRIVATE_ZONE__"
Environment="DB_PORT=3306"
Environment="DB_NAME=__DB_NAME__"
Environment="DB_USER=__DB_USER__"
Environment="DB_PASS=__DB_PASS__"
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now selfapp

echo "app01 setup complete. selfapp-lite starting on :8080"
