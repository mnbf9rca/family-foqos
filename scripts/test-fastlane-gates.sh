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

mkdir -p "$TEST_ROOT/bin"

cat >"$TEST_ROOT/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "label list")
    if [[ "${FAKE_LABEL_PRESENT:-0}" -eq 1 ]]; then
      printf '[{"name":"release-blocking"}]\n'
    else
      printf '[]\n'
    fi
    ;;
  "issue list")
    printf '%s\n' "${FAKE_ISSUES_JSON:-[]}"
    ;;
  *)
    echo "unexpected gh command: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$TEST_ROOT/bin/xcrun" <<'EOF'
#!/bin/bash
sed '/^#/d; /^$/d; s/$/ (/' "$FAKE_SCHEMA_FILE"
EOF

chmod +x "$TEST_ROOT/bin/gh" "$TEST_ROOT/bin/xcrun"

run_gates() {
  set +e
  GATE_OUTPUT=$(
    PATH="$TEST_ROOT/bin:$PATH" \
      FAKE_SCHEMA_FILE="$REPO_ROOT/fastlane/required-prod-schema.txt" \
      bundle exec fastlane gates 2>&1
  )
  GATE_STATUS=$?
  set -e
}

FAKE_LABEL_PRESENT=0 \
  FAKE_ISSUES_JSON='[{"number":999,"title":"fake blocker"}]' \
  run_gates
if [[ "$GATE_STATUS" -eq 0 || "$GATE_OUTPUT" != *"Required GitHub label is missing: release-blocking"* ]]; then
  echo "FAIL: missing release-blocking label must abort the gate"
  echo "actual exit: $GATE_STATUS"
  echo "$GATE_OUTPUT"
  exit 1
fi

FAKE_LABEL_PRESENT=1 run_gates
if [[ "$GATE_STATUS" -ne 0 ]]; then
  echo "FAIL: existing label with no blockers and a matching schema must pass"
  echo "$GATE_OUTPUT"
  exit 1
fi

echo "PASS: release-blocking label gate cases"
