#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/fastlane.sh"
REFS_FILE="$REPO_ROOT/fastlane/asc.env"
TEST_ROOT=$(mktemp -d)

cleanup() {
  if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

if [[ ! -x "$WRAPPER" ]]; then
  echo "FAIL: scripts/fastlane.sh is missing or not executable"
  exit 1
fi
if [[ ! -f "$REFS_FILE" ]]; then
  echo "FAIL: fastlane/asc.env is missing"
  exit 1
fi

REF_LINES=()
while IFS= read -r line; do
  REF_LINES+=("$line")
done < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$REFS_FILE")
EXPECTED_REFS=(
  'ASC_KEY_ID=op://family-foqos/app_store_connect_key/ASC_KEY_ID_REF'
  'ASC_ISSUER_ID=op://family-foqos/app_store_connect_key/ASC_ISSUER_ID_REF'
  'ASC_KEY_CONTENT_BASE64=op://family-foqos/app_store_connect_key/ASC_KEY_CONTENT_BASE64_REF'
)
if [[ "${REF_LINES[*]}" != "${EXPECTED_REFS[*]}" ]]; then
  echo "FAIL: fastlane/asc.env does not contain exactly the three approved mappings"
  exit 1
fi

mkdir -p "$TEST_ROOT/bootstrap" "$TEST_ROOT/ruby/bin" "$TEST_ROOT/no-op-ruby/bin"

cat >"$TEST_ROOT/bootstrap/brew" <<EOF
#!/bin/bash
if [[ "\${1:-}" != "--prefix" || "\${2:-}" != "ruby" ]]; then
  echo "unexpected brew arguments: \$*" >&2
  exit 64
fi
printf '%s\n' "\${FAKE_RUBY_PREFIX}"
EOF

cat >"$TEST_ROOT/ruby/bin/op" <<'EOF'
#!/bin/bash
printf 'op' >"$COMMAND_LOG"
printf '\t%s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
EOF

cat >"$TEST_ROOT/ruby/bin/bundle" <<'EOF'
#!/bin/bash
printf 'bundle' >"$COMMAND_LOG"
printf '\t%s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
EOF

cp "$TEST_ROOT/ruby/bin/bundle" "$TEST_ROOT/no-op-ruby/bin/bundle"
chmod +x "$TEST_ROOT/bootstrap/brew" "$TEST_ROOT/ruby/bin/op" \
  "$TEST_ROOT/ruby/bin/bundle" "$TEST_ROOT/no-op-ruby/bin/bundle"

run_wrapper() {
  local ruby_prefix=$1
  shift
  COMMAND_LOG="$TEST_ROOT/command.log" \
    FAKE_RUBY_PREFIX="$ruby_prefix" \
    PATH="$TEST_ROOT/bootstrap:/usr/bin:/bin" \
    "$WRAPPER" "$@"
}

for lane in check_asc_key pull_metadata beta release; do
  run_wrapper "$TEST_ROOT/ruby" "$lane" "argument with spaces"
  printf -v expected 'op\trun\t--env-file\t%s\t--\tbundle\texec\tfastlane\t%s\targument with spaces' \
    "$REPO_ROOT/scripts/../fastlane/asc.env" "$lane"
  if [[ "$(<"$TEST_ROOT/command.log")" != "$expected" ]]; then
    echo "FAIL: credential lane $lane was not routed through op run"
    printf 'actual: %s\n' "$(<"$TEST_ROOT/command.log")"
    exit 1
  fi
done

for lane in screenshots lanes gates build_number; do
  run_wrapper "$TEST_ROOT/ruby" "$lane" "argument with spaces"
  printf -v expected 'bundle\texec\tfastlane\t%s\targument with spaces' "$lane"
  if [[ "$(<"$TEST_ROOT/command.log")" != "$expected" ]]; then
    echo "FAIL: non-credential lane $lane did not bypass op"
    printf 'actual: %s\n' "$(<"$TEST_ROOT/command.log")"
    exit 1
  fi
done

set +e
MISSING_OP_OUTPUT=$(run_wrapper "$TEST_ROOT/no-op-ruby" check_asc_key 2>&1)
MISSING_OP_STATUS=$?
set -e
if [[ "$MISSING_OP_STATUS" -eq 0 || "$MISSING_OP_OUTPUT" != *"1Password CLI 'op' is required"* ]]; then
  echo "FAIL: missing op must fail with a friendly error"
  printf 'exit: %s\n%s\n' "$MISSING_OP_STATUS" "$MISSING_OP_OUTPUT"
  exit 1
fi

echo "PASS: Fastlane credential routing and reference mappings"
