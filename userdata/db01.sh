#!/bin/bash
# =============================================================================
# db01 — MySQL 8.4 LTS (Oracle community repo; AL2023 doesn't ship MySQL)
# Creates the app database and user. Passwords are read from SSM Parameter
# Store at boot via the instance role — they never appear in user data.
# Double-underscore tokens are filled in by 03-backends.sh (non-secret values only).
# Log: /var/log/userdata-db01.log
# =============================================================================
set -euo pipefail
exec > /var/log/userdata-db01.log 2>&1
trap 'echo "FAILED at line $LINENO"' ERR

get_secret() {  # retries: the role's credentials can take a moment at boot
  local _
  for _ in {1..10}; do
    aws ssm get-parameter --region "__AWS_REGION__" --name "__SSM_PREFIX__/$1" \
      --with-decryption --query Parameter.Value --output text && return 0
    sleep 5
  done
  return 1
}

# 1 GiB of swap: MySQL 8 on a 1 GiB t2.micro is tight without it
dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap defaults 0 0' >> /etc/fstab

dnf -y upgrade
dnf -y install https://dev.mysql.com/get/mysql84-community-release-el9-1.noarch.rpm
dnf -y install mysql-community-server

# Before first start: relax the password plugin to "length only" (our
# passwords are validated as 12+ chars by lib.sh) and listen on all interfaces
# (the security group limits who can connect).
cat >> /etc/my.cnf <<'CNF'

[mysqld]
bind-address = 0.0.0.0
loose-validate_password.policy = LOW
CNF

systemctl enable --now mysqld

for i in {1..30}; do
  mysqladmin ping --silent && break
  echo "Waiting for MySQL... ($i)"; sleep 2
done

DB_ROOT_PASS=$(get_secret db-root-pass)
DB_PASS=$(get_secret db-pass)

# First start generates a random, expired root password in the log
TEMP_PASS=$(grep -oP 'temporary password.*: \K\S+' /var/log/mysqld.log | tail -1)
mysql --connect-expired-password -uroot -p"$TEMP_PASS" \
  -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';"

# Use an option file so the root password isn't visible in the process list
MYCNF=$(mktemp) && chmod 600 "$MYCNF"
printf '[client]\nuser=root\npassword=%s\n' "$DB_ROOT_PASS" > "$MYCNF"
mysql --defaults-extra-file="$MYCNF" <<SQL
CREATE DATABASE IF NOT EXISTS __DB_NAME__;
CREATE USER IF NOT EXISTS '__DB_USER__'@'%' IDENTIFIED BY '${DB_PASS}';
ALTER USER '__DB_USER__'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON __DB_NAME__.* TO '__DB_USER__'@'%';
SQL
rm -f "$MYCNF"

echo "db01 setup complete: MySQL listening on :3306"
