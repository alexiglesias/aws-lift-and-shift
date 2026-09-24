#!/usr/bin/env bash
# =============================================================================
# tests/test.sh — offline checks, no AWS account or credentials needed.
#   - config validation accepts good input and rejects bad input
#   - every template renders with no leftover __PLACEHOLDER__ tokens
#   - rendered user data is valid bash; rendered IAM policy is valid JSON
# Runs in CI on Linux and on macOS's stock Bash 3.2. Run locally with:
#   bash tests/test.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0 FAILED=0
ok()  { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
bad() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SELFAPP_CONFIG="$TMP/config.sh"

# A valid config: the example plus test values (later exports win)
make_config() {
  cp config.sh.example "$SELFAPP_CONFIG"
  cat >> "$SELFAPP_CONFIG" <<'CFG'
export YOUR_IP="203.0.113.10"
export DB_PASS="TestDbPass1234"
export DB_ROOT_PASS="TestRootPass1234"
export RMQ_PASS="TestRabbitPass1234"
CFG
}

# Loads lib.sh in a subshell using the SAME bash running this test
loads_ok() { "$BASH" -c 'source scripts/lib.sh' >/dev/null 2>&1; }

echo "Bash version: $BASH_VERSION"
echo "--- Config validation ---"

rm -f "$SELFAPP_CONFIG"
if loads_ok; then bad "missing config was accepted"; else ok "missing config is rejected"; fi

cp config.sh.example "$SELFAPP_CONFIG"
if loads_ok; then bad "unfilled example config was accepted"; else ok "unfilled example config is rejected"; fi

make_config
if loads_ok; then ok "valid config is accepted"; else bad "valid config was rejected"; fi

check_rejected() {  # $1 = description, $2 = config line to append
  make_config
  echo "$2" >> "$SELFAPP_CONFIG"
  if loads_ok; then bad "$1 was accepted"; else ok "$1 is rejected"; fi
}
check_rejected "short password"          'export DB_PASS="short1"'
check_rejected "password with a quote"   "export RMQ_PASS=\"has'quote123456\""
check_rejected "malformed YOUR_IP"       'export YOUR_IP="not-an-ip"'
check_rejected "unsafe DB_NAME"          'export DB_NAME="bad name;"'
check_rejected "invalid bucket name"     'export BUCKET_NAME="Bad_Bucket"'

echo "--- Template rendering ---"
make_config
render() {  # $1 = template → stdout
  "$BASH" -c 'source scripts/lib.sh
              ACCOUNT_ID=123456789012 BUCKET_NAME=selfapp-artifacts-123456789012
              render_template "$1"' _ "$1"
}

for TEMPLATE in userdata/*.sh; do
  render "$TEMPLATE" > "$TMP/rendered.sh"
  if grep -q '__[A-Z_]*__' "$TMP/rendered.sh"; then
    bad "$TEMPLATE has unrendered placeholders: $(grep -o '__[A-Z_]*__' "$TMP/rendered.sh" | sort -u | tr '\n' ' ')"
  elif ! bash -n "$TMP/rendered.sh"; then
    bad "$TEMPLATE renders to invalid bash"
  else
    ok "$TEMPLATE renders to valid bash"
  fi
  if grep -q 'TestDbPass1234\|TestRootPass1234\|TestRabbitPass1234' "$TMP/rendered.sh"; then
    bad "$TEMPLATE leaks a password into user data"
  fi
done

render iam/ec2-permissions.json > "$TMP/policy.json"
if python3 -m json.tool "$TMP/policy.json" >/dev/null 2>&1 && ! grep -q '__[A-Z_]*__' "$TMP/policy.json"; then
  ok "iam/ec2-permissions.json renders to valid JSON"
else
  bad "iam/ec2-permissions.json renders to invalid JSON or has placeholders"
fi

echo ""
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
