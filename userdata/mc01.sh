#!/bin/bash
# =============================================================================
# mc01 — Memcached 1.6
# Listens on all interfaces (0.0.0.0) so app01 can reach it via private IP.
# selfapp-lite doesn't wire Memcached yet — this is kept as a stretch exercise.
# =============================================================================
set -euo pipefail
exec > /var/log/userdata-mc01.log 2>&1

dnf update -y
dnf install -y memcached

# Bind to all interfaces instead of loopback-only
sed -i 's/OPTIONS="-l 127.0.0.1"/OPTIONS="-l 0.0.0.0"/' /etc/sysconfig/memcached

systemctl enable --now memcached

echo "mc01 setup complete. Memcached listening on :11211"
