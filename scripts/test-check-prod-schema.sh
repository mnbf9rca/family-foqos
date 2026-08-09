#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)

cleanup() {
  if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/fastlane" "$TEST_ROOT/scripts"
cp "$REPO_ROOT/scripts/check-prod-schema.sh" "$TEST_ROOT/scripts/check-prod-schema.sh"

cat >"$TEST_ROOT/bin/xcrun" <<'EOF'
#!/bin/bash
if [[ "${FAKE_CKTOOL_EXIT:-0}" -ne 0 ]]; then
  exit "$FAKE_CKTOOL_EXIT"
fi
printf '%s\n' "${FAKE_SCHEMA:-}"
EOF
chmod +x "$TEST_ROOT/bin/xcrun"

run_gate() {
  set +e
  GATE_OUTPUT=$(PATH="$TEST_ROOT/bin:$PATH" "$TEST_ROOT/scripts/check-prod-schema.sh" 2>&1)
  GATE_STATUS=$?
  set -e
}

printf '# comments do not count\n\n' >"$TEST_ROOT/fastlane/required-prod-schema.txt"
run_gate
if [[ "$GATE_STATUS" -ne 2 || "$GATE_OUTPUT" != *"empty or unreadable"* ]]; then
  echo "FAIL: comment-only manifest must exit 2 with an empty-or-unreadable error"
  echo "actual exit: $GATE_STATUS"
  echo "$GATE_OUTPUT"
  exit 1
fi
EMPTY_OUTPUT=$GATE_OUTPUT
EMPTY_STATUS=$GATE_STATUS

printf 'RECORD TYPE Present\n' >"$TEST_ROOT/fastlane/required-prod-schema.txt"
FAKE_SCHEMA='RECORD TYPE Present' run_gate
if [[ "$GATE_STATUS" -ne 0 || "$GATE_OUTPUT" != *"Production schema OK."* ]]; then
  echo "FAIL: matching production schema must pass"
  exit 1
fi

FAKE_SCHEMA='' run_gate
if [[ "$GATE_STATUS" -ne 1 || "$GATE_OUTPUT" != *"MISSING in production schema: RECORD TYPE Present"* ]]; then
  echo "FAIL: missing production record type must exit 1"
  exit 1
fi

FAKE_CKTOOL_EXIT=42 run_gate
if [[ "$GATE_STATUS" -ne 42 ]]; then
  echo "FAIL: cktool query failure must retain its distinct exit code"
  echo "actual exit: $GATE_STATUS"
  exit 1
fi
QUERY_FAILURE_STATUS=$GATE_STATUS

echo "$EMPTY_OUTPUT"
echo "empty-manifest exit: $EMPTY_STATUS"
echo "forced-cktool exit: $QUERY_FAILURE_STATUS"
echo "PASS: production-schema gate cases"
