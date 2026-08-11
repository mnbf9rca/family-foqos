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
printf '%s\n' "$*" >>"$FAKE_XCRUN_LOG"
if [[ "${1:-}" == "--find" && "${2:-}" == "cktool" ]]; then
  [[ "${FAKE_CKTOOL_AVAILABLE:-1}" -eq 1 ]] || exit 1
  printf '/fake/cktool\n'
  exit 0
fi
[[ "${1:-}" == "cktool" && "${2:-}" == "export-schema" ]] || exit 64
if [[ "${FAKE_CKTOOL_EXIT:-0}" -ne 0 ]]; then
  exit "$FAKE_CKTOOL_EXIT"
fi
printf '%s\n' "${FAKE_SCHEMA:-}"
EOF
chmod +x "$TEST_ROOT/bin/xcrun"

run_gate() {
  set +e
  GATE_OUTPUT=$(FAKE_XCRUN_LOG="$TEST_ROOT/xcrun.log" PATH="$TEST_ROOT/bin:$PATH" \
    "$TEST_ROOT/scripts/check-prod-schema.sh" 2>&1)
  GATE_STATUS=$?
  set -e
}

run_gate
if [[ "$GATE_STATUS" -ne 2 || "$GATE_OUTPUT" != *"empty or unreadable"* ]]; then
  echo "FAIL: missing manifest must exit 2 with an empty-or-unreadable error"
  exit 1
fi

printf 'RECORD TYPE Unreadable\n' >"$TEST_ROOT/fastlane/required-prod-schema.txt"
chmod 000 "$TEST_ROOT/fastlane/required-prod-schema.txt"
run_gate
chmod 600 "$TEST_ROOT/fastlane/required-prod-schema.txt"
if [[ "$GATE_STATUS" -ne 2 || "$GATE_OUTPUT" != *"empty or unreadable"* ]]; then
  echo "FAIL: unreadable manifest must exit 2 with an empty-or-unreadable error"
  echo "actual exit: $GATE_STATUS"
  echo "$GATE_OUTPUT"
  exit 1
fi

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
: >"$TEST_ROOT/xcrun.log"
FAKE_CKTOOL_AVAILABLE=0 run_gate
if [[ "$GATE_STATUS" -ne 1 || "$GATE_OUTPUT" != *"cktool"* ]]; then
  echo "FAIL: unavailable cktool must exit 1 and name cktool"
  echo "actual exit: $GATE_STATUS"
  echo "$GATE_OUTPUT"
  exit 1
fi
if grep -F 'cktool export-schema' "$TEST_ROOT/xcrun.log" >/dev/null; then
  echo "FAIL: unavailable cktool reached schema export"
  exit 1
fi

FAKE_SCHEMA='RECORD TYPE Present (' run_gate
if [[ "$GATE_STATUS" -ne 0 || "$GATE_OUTPUT" != *"Production schema OK."* ]]; then
  echo "FAIL: matching production schema must pass"
  exit 1
fi

FAKE_SCHEMA='RECORD TYPE PresentExtra (' run_gate
if [[ "$GATE_STATUS" -ne 1 ]]; then
  echo "FAIL: a prefixed record type must not satisfy the exact requirement"
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
