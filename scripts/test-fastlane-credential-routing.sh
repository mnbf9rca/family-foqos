#!/bin/bash
set -euo pipefail

# Keep this list in sync whenever the suite starts invoking another external tool.
required_commands=(cat chmod cp dirname mkdir mktemp rm sed)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "FAIL: required command not found: $required_command" >&2
    exit 127
  }
done

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

mkdir -p "$TEST_ROOT/bootstrap" "$TEST_ROOT/failing-brew" "$TEST_ROOT/ruby/bin" \
  "$TEST_ROOT/no-op-ruby/bin" "$TEST_ROOT/no-xcbeautify-ruby/bin"

cat >"$TEST_ROOT/bootstrap/brew" <<EOF
#!/bin/bash
if [[ "\${1:-}" != "--prefix" || "\${2:-}" != "ruby" ]]; then
  echo "unexpected brew arguments: \$*" >&2
  exit 64
fi
printf '%s\n' "\${FAKE_RUBY_PREFIX}"
EOF

cat >"$TEST_ROOT/failing-brew/brew" <<'EOF'
#!/bin/bash
exit 1
EOF

cat >"$TEST_ROOT/ruby/bin/op" <<'EOF'
#!/bin/bash
printf 'op' >>"$COMMAND_LOG"
printf '\t%s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
printf 'op\t%s\t%s\n' "${BUNDLE_PATH-}" "${BUNDLE_FROZEN-}" >>"$ENV_LOG"
EOF

cat >"$TEST_ROOT/ruby/bin/bundle" <<'EOF'
#!/bin/bash
printf 'bundle' >>"$COMMAND_LOG"
printf '\t%s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
printf 'bundle\t%s\t%s\n' "${BUNDLE_PATH-}" "${BUNDLE_FROZEN-}" >>"$ENV_LOG"
case "${1:-}" in
  --version)
    exit "${BUNDLE_VERSION_EXIT:-0}"
    ;;
  check)
    exit "${BUNDLE_CHECK_EXIT:-0}"
    ;;
  install)
    exit "${BUNDLE_INSTALL_EXIT:-0}"
    ;;
  exec)
    exit 0
    ;;
  *)
    exit 64
    ;;
esac
EOF

cat >"$TEST_ROOT/ruby/bin/xcbeautify" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "--version" ]] || exit 64
exit "${XCBEAUTIFY_PREFLIGHT_EXIT:-0}"
EOF

cp "$TEST_ROOT/ruby/bin/bundle" "$TEST_ROOT/no-op-ruby/bin/bundle"
cp "$TEST_ROOT/ruby/bin/op" "$TEST_ROOT/no-xcbeautify-ruby/bin/op"
cp "$TEST_ROOT/ruby/bin/bundle" "$TEST_ROOT/no-xcbeautify-ruby/bin/bundle"
chmod +x "$TEST_ROOT/bootstrap/brew" "$TEST_ROOT/failing-brew/brew" "$TEST_ROOT/ruby/bin/op" \
  "$TEST_ROOT/ruby/bin/bundle" "$TEST_ROOT/ruby/bin/xcbeautify" \
  "$TEST_ROOT/no-op-ruby/bin/bundle" "$TEST_ROOT/no-xcbeautify-ruby/bin/op" \
  "$TEST_ROOT/no-xcbeautify-ruby/bin/bundle"

assert_ruby_prerequisite_failure() {
  local test_name=$1
  local test_path=$2
  local output
  local status

  set +e
  output=$(PATH="$test_path" "$WRAPPER" lanes 2>&1)
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"brew install ruby"* ]]; then
    echo "FAIL: $test_name must fail with the Homebrew Ruby prerequisite"
    printf 'exit: %s\n%s\n' "$status" "$output"
    exit 1
  fi
}

assert_ruby_prerequisite_failure "missing brew" "/usr/bin:/bin"
assert_ruby_prerequisite_failure \
  "missing Homebrew Ruby formula" "$TEST_ROOT/failing-brew:/usr/bin:/bin"

run_wrapper() {
  local ruby_prefix=$1
  shift
  rm -f "$TEST_ROOT/command.log" "$TEST_ROOT/env.log"
  COMMAND_LOG="$TEST_ROOT/command.log" \
    ENV_LOG="$TEST_ROOT/env.log" \
    FAKE_RUBY_PREFIX="$ruby_prefix" \
    BUNDLE_PATH="/must/not/use/inherited/bundle/path" \
    BUNDLE_FROZEN=false \
    PATH="$TEST_ROOT/bootstrap:/usr/bin:/bin" \
    "$WRAPPER" "$@"
}

assert_local_bundle_environment() {
  local expected_path="$REPO_ROOT/vendor/bundle"
  local tool
  local path
  local frozen
  local count=0

  while IFS=$'\t' read -r tool path frozen; do
    count=$((count + 1))
    if [[ "$path" != "$expected_path" || "$frozen" != true ]]; then
      echo "FAIL: $tool escaped the frozen repo-local bundle environment"
      printf 'path: %s\nfrozen: %s\n' "$path" "$frozen"
      exit 1
    fi
  done <"$TEST_ROOT/env.log"
  if [[ "$count" -eq 0 ]]; then
    echo "FAIL: wrapper crossed no observable bundle boundary"
    exit 1
  fi
}

for lane in check_asc_key pull_metadata beta release verify_export; do
  run_wrapper "$TEST_ROOT/ruby" "$lane" "argument with spaces"
  printf -v expected 'bundle\t--version\nbundle\tcheck\nop\trun\t--env-file\t%s\t--\tbundle\texec\tfastlane\t%s\targument with spaces' \
    "$REPO_ROOT/scripts/../fastlane/asc.env" "$lane"
  if [[ "$(<"$TEST_ROOT/command.log")" != "$expected" ]]; then
    echo "FAIL: credential lane $lane was not routed through op run"
    printf 'actual: %s\n' "$(<"$TEST_ROOT/command.log")"
    exit 1
  fi
  assert_local_bundle_environment
done

for lane in screenshots lanes gates build_number; do
  run_wrapper "$TEST_ROOT/ruby" "$lane" "argument with spaces"
  printf -v expected 'bundle\t--version\nbundle\tcheck\nbundle\texec\tfastlane\t%s\targument with spaces' \
    "$lane"
  if [[ "$(<"$TEST_ROOT/command.log")" != "$expected" ]]; then
    echo "FAIL: non-credential lane $lane did not bypass op"
    printf 'actual: %s\n' "$(<"$TEST_ROOT/command.log")"
    exit 1
  fi
  assert_local_bundle_environment
done

BUNDLE_CHECK_EXIT=1 run_wrapper "$TEST_ROOT/ruby" lanes
expected=$'bundle\t--version\nbundle\tcheck\nbundle\tinstall\nbundle\texec\tfastlane\tlanes'
if [[ "$(<"$TEST_ROOT/command.log")" != "$expected" ]]; then
  echo "FAIL: missing dependencies were not installed before lane execution"
  printf 'actual: %s\n' "$(<"$TEST_ROOT/command.log")"
  exit 1
fi
assert_local_bundle_environment

set +e
output=$(BUNDLE_CHECK_EXIT=1 BUNDLE_INSTALL_EXIT=23 \
  run_wrapper "$TEST_ROOT/ruby" verify_export 2>&1)
status=$?
set -e
expected=$'bundle\t--version\nbundle\tcheck\nbundle\tinstall'
if [[ "$status" -eq 0 || "$output" != *"Fastlane dependencies could not be installed"* ]]; then
  echo "FAIL: dependency installation failure must be named and nonzero"
  printf 'exit: %s\n%s\n' "$status" "$output"
  exit 1
fi
if [[ "$(<"$TEST_ROOT/command.log")" != "$expected" ]]; then
  echo "FAIL: dependency installation failure reached credentials or a lane"
  printf 'actual: %s\n' "$(<"$TEST_ROOT/command.log")"
  exit 1
fi
assert_local_bundle_environment

set +e
output=$(BUNDLE_VERSION_EXIT=19 run_wrapper "$TEST_ROOT/ruby" lanes 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 || "$output" != *"Bundler is unavailable"* ]]; then
  echo "FAIL: unavailable Bundler must be named and rejected"
  printf 'exit: %s\n%s\n' "$status" "$output"
  exit 1
fi
if [[ "$(<"$TEST_ROOT/command.log")" != $'bundle\t--version' ]]; then
  echo "FAIL: unavailable Bundler reached dependency or lane execution"
  printf 'actual: %s\n' "$(<"$TEST_ROOT/command.log")"
  exit 1
fi
assert_local_bundle_environment

for lane in screenshots beta release verify_export; do
  set +e
  output=$(run_wrapper "$TEST_ROOT/no-xcbeautify-ruby" "$lane" 2>&1)
  status=$?
  set -e
  if [[ "$status" -ne 127 || "$output" != *"xcbeautify"* ]]; then
    echo "FAIL: formatter lane $lane must reject missing xcbeautify before credentials"
    printf 'exit: %s\n%s\n' "$status" "$output"
    exit 1
  fi
  if [[ -e "$TEST_ROOT/command.log" ]]; then
    echo "FAIL: missing xcbeautify invoked op or bundle for $lane"
    exit 1
  fi

  set +e
  output=$(XCBEAUTIFY_PREFLIGHT_EXIT=19 run_wrapper "$TEST_ROOT/ruby" "$lane" 2>&1)
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"xcbeautify"* ]]; then
    echo "FAIL: formatter lane $lane must reject failed xcbeautify preflight"
    printf 'exit: %s\n%s\n' "$status" "$output"
    exit 1
  fi
  if [[ -e "$TEST_ROOT/command.log" ]]; then
    echo "FAIL: unavailable xcbeautify invoked op or bundle for $lane"
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
if [[ -e "$TEST_ROOT/command.log" ]]; then
  echo "FAIL: missing op invoked bundle"
  exit 1
fi

echo "PASS: Fastlane credential routing and reference mappings"
