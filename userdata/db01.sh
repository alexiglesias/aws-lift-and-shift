#!/bin/bash
# =============================================================================
# db01 — MySQL 8.0
# Installs MySQL, creates the selfapplite database and selfuser.
# DB_NAME, DB_USER, DB_PASS, DB_ROOT_PASS are injected by 03-backends.sh
# via sed substitution before this script is sent to EC2.
# =============================================================================
set -euo pipefail
exec > /var/log/userdata-db01.log 2>&1

dnf update -y
dnf install -y mysql-server
systemctl enable --now mysqld

# Wait for MySQL to be ready
for i in {1..30}; do
  mysqladmin ping --silent && break
  echo "Waiting for MySQL... ($i)"
  sleep 2
done

mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '__DB_ROOT_PASS__';
CREATE DATABASE IF NOT EXISTS __DB_NAME__;
CREATE USER IF NOT EXISTS '__DB_USER__'@'%' IDENTIFIED BY '__DB_PASS__';
GRANT ALL PRIVILEGES ON __DB_NAME__.* TO '__DB_USER__'@'%';
FLUSH PRIVILEGES;
SQL

echo "db01 setup complete."
