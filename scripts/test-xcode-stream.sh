#!/opt/homebrew/bin/bash
set -euo pipefail

# Keep this list in sync whenever the suite starts invoking another external tool.
required_commands=(
  /opt/homebrew/bin/bash
  /opt/homebrew/bin/jq
  /usr/bin/true
  basename
  cat
  chmod
  cmp
  dirname
  grep
  mkdir
  mktemp
  mv
  rm
  zsh
)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "FAIL: required command not found: $required_command" >&2
    exit 127
  }
done
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "FAIL: Bash 4+ is required" >&2
  exit 127
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/xcode-stream.sh"
ADAPTER="$REPO_ROOT/scripts/ios-sim-gate-bin/xcrun"
JQ_BIN=/opt/homebrew/bin/jq
TEST_ROOT=$(mktemp -d)
mkdir -p "$TEST_ROOT/bin"

REUSE_UUID=11111111-1111-1111-1111-111111111111
SESSION_UUID=22222222-2222-2222-2222-222222222222
OTHER_UUID=33333333-3333-3333-3333-333333333333
CREATED_UUID=44444444-4444-4444-4444-444444444444
WINNER_UUID=55555555-5555-5555-5555-555555555555
STALE_UUID=66666666-6666-6666-6666-666666666666

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local path=$1
  local expected=$2
  grep -F -- "$expected" "$path" >/dev/null ||
    fail "$path does not contain: $expected"
}

assert_not_contains() {
  local path=$1
  local unexpected=$2
  if grep -F -- "$unexpected" "$path" >/dev/null; then
    fail "$path unexpectedly contains: $unexpected"
  fi
}

write_fake_gate() {
  cat >"$TEST_ROOT/bin/ios-sim-gate" <<'EOF'
#!/opt/homebrew/bin/bash
set -euo pipefail

registry="$IOS_SIM_GATE_HOME/registry.json"
mkdir -p "$IOS_SIM_GATE_HOME"
[[ -f "$registry" ]] || printf '{}\n' >"$registry"
command=$1
shift

parse_owner() {
  project=""
  agent=""
  session=""
  uuid=""
  while (($#)); do
    case "$1" in
      --project) project=$2; shift 2 ;;
      --agent) agent=$2; shift 2 ;;
      --session) session=$2; shift 2 ;;
      --udid) uuid=$2; shift 2 ;;
      --) shift; child=("$@"); break ;;
      *) echo "unexpected gate argument: $1" >&2; exit 64 ;;
    esac
  done
}

case "$command" in
  status)
    printf 'capacity slots=3 admission=free\n'
    exit "${GATE_STATUS_EXIT:-0}"
    ;;
  reconcile)
    printf 'reconciled\n' >>"$GATE_LOG"
    temporary="$registry.tmp"
    "$JQ_BIN" --slurpfile devices "$DEVICES_JSON" '
      with_entries(
        select(.key as $uuid | any($devices[0].devices[]?[]?; .udid == $uuid))
      )
    ' "$registry" >"$temporary"
    mv "$temporary" "$registry"
    ;;
  register)
    parse_owner "$@"
    printf 'register\t%s\t%s\t%s\t%s\n' "$project" "$agent" "$session" "$uuid" \
      >>"$GATE_LOG"
    if [[ "${SIMULATE_REGISTER_RACE:-0}" == 1 ]]; then
      temporary="$registry.tmp"
      "$JQ_BIN" --arg uuid "$WINNER_UUID" --arg project "$project" --arg agent "$agent" \
        --arg session "$session" \
        '. + {($uuid): {project: $project, agent: $agent, session: $session,
          lastupdated: "2026-08-10T00:00:00Z"}}' "$registry" >"$temporary"
      mv "$temporary" "$registry"
      echo "owner already registered" >&2
      exit 1
    fi
    temporary="$registry.tmp"
    "$JQ_BIN" --arg uuid "$uuid" --arg project "$project" --arg agent "$agent" \
      --arg session "$session" \
      '. + {($uuid): {project: $project, agent: $agent, session: $session,
        lastupdated: "2026-08-10T00:00:00Z"}}' "$registry" >"$temporary"
    mv "$temporary" "$registry"
    ;;
  run)
    child=()
    parse_owner "$@"
    printf 'run\t%s\t%s\t%s\t%s\n' "$project" "$agent" "$session" "$uuid" >>"$GATE_LOG"
    export IOS_SIM_GATE_UDID="$uuid"
    export IOS_SIM_GATE_DESTINATION="platform=iOS Simulator,id=$uuid"
    export IOS_SIM_GATE_DERIVED_DATA_PATH="$IOS_SIM_GATE_CACHE_HOME/DerivedData/$project/$agent/${session:-no-session}"
    export IOS_SIM_GATE_PROJECT="$project"
    export IOS_SIM_GATE_AGENT="$agent"
    if [[ -n "$session" ]]; then
      export IOS_SIM_GATE_SESSION="$session"
    else
      unset IOS_SIM_GATE_SESSION || true
    fi
    mkdir -p "$IOS_SIM_GATE_DERIVED_DATA_PATH"
    exec "${child[@]}"
    ;;
  *)
    echo "unexpected gate command: $command" >&2
    exit 64
    ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/ios-sim-gate"
}

write_fake_simctl() {
  cat >"$TEST_ROOT/bin/simctl" <<'EOF'
#!/opt/homebrew/bin/bash
set -euo pipefail

printf '%s\n' "$*" >>"$SIMCTL_LOG"
case "$1 $2 ${3:-}" in
  "list devices available")
    "$JQ_BIN" '
      .devices |= with_entries(.value |= map(select(.isAvailable != false)))
    ' "$DEVICES_JSON"
    ;;
  "list devices --json")
    cat "$DEVICES_JSON"
    ;;
  "list devicetypes --json")
    cat "$DEVICE_TYPES_JSON"
    ;;
  "list runtimes available")
    cat "$RUNTIMES_JSON"
    ;;
  "create "*)
    name=$2
    device_type=$3
    runtime=$4
    if [[ -n "${INCOMPATIBLE_RUNTIME:-}" && "$runtime" == "$INCOMPATIBLE_RUNTIME" ]]; then
      echo "incompatible runtime" >&2
      exit 1
    fi
    uuid=$(<"$NEXT_UUID_FILE")
    temporary="$DEVICES_JSON.tmp"
    "$JQ_BIN" --arg uuid "$uuid" --arg name "$name" --arg runtime "$runtime" \
      --arg device_type "$device_type" '
      .devices[$runtime] = ((.devices[$runtime] // []) + [{
        udid: $uuid,
        name: $name,
        state: "Shutdown",
        isAvailable: true,
        dataPathSize: 0,
        deviceTypeIdentifier: $device_type
      }])
    ' "$DEVICES_JSON" >"$temporary"
    mv "$temporary" "$DEVICES_JSON"
    printf '%s\n' "$uuid"
    ;;
  "shutdown "*)
    ;;
  "delete "*)
    uuid=$2
    temporary="$DEVICES_JSON.tmp"
    "$JQ_BIN" --arg uuid "$uuid" '
      .devices |= with_entries(.value |= map(select(.udid != $uuid)))
    ' "$DEVICES_JSON" >"$temporary"
    mv "$temporary" "$DEVICES_JSON"
    ;;
  *)
    echo "unexpected simctl arguments: $*" >&2
    exit 64
    ;;
esac
EOF
  chmod +x "$TEST_ROOT/bin/simctl"
}

write_fake_xcodebuild() {
  cat >"$TEST_ROOT/bin/xcodebuild" <<'EOF'
#!/opt/homebrew/bin/bash
printf '%s\n' "$@" >"$XCODEBUILD_LOG"
[[ -z "${XCODEBUILD_STDOUT:-}" ]] || printf '%s\n' "$XCODEBUILD_STDOUT"
[[ -z "${XCODEBUILD_STDERR:-}" ]] || printf '%s\n' "$XCODEBUILD_STDERR" >&2
exit "${XCODEBUILD_EXIT:-0}"
EOF
  chmod +x "$TEST_ROOT/bin/xcodebuild"
}

write_fake_xcpretty() {
  cat >"$TEST_ROOT/bin/bundle" <<'EOF'
#!/opt/homebrew/bin/bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == "exec" && "$2" == "xcpretty" ]] || exit 64
cat >"$XCPRETTY_INPUT_LOG"
exit "${XCPRETTY_EXIT:-0}"
EOF
  chmod +x "$TEST_ROOT/bin/bundle"
}

write_fake_fastlane_dependencies() {
  mkdir -p "$TEST_ROOT/ruby/bin"
  cat >"$TEST_ROOT/bin/brew" <<'EOF'
#!/opt/homebrew/bin/bash
set -euo pipefail
[[ "$*" == "--prefix ruby" ]] || exit 64
printf '%s\n' "$PATH" >"$FASTLANE_ENTRY_PATH_LOG"
printf '%s\n' "$FAKE_RUBY_PREFIX"
EOF
  cat >"$TEST_ROOT/ruby/bin/bundle" <<'EOF'
#!/opt/homebrew/bin/bash
set -euo pipefail
printf '%s\n' "$PATH" >"$FASTLANE_CHILD_PATH_LOG"
printf '%s\n' "$@" >"$FASTLANE_ARGS_LOG"
EOF
  cat >"$TEST_ROOT/bin/real-xcrun" <<'EOF'
#!/opt/homebrew/bin/bash
set -euo pipefail
printf '<%s>\n' "$@" >"$REAL_XCRUN_LOG"
EOF
  chmod +x "$TEST_ROOT/bin/brew" "$TEST_ROOT/ruby/bin/bundle" "$TEST_ROOT/bin/real-xcrun"
}

write_inventory_files() {
  cat >"$TEST_ROOT/device-types.json" <<'EOF'
{
  "devicetypes": [
    {"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
    {"name":"iPhone 17 Pro Max","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"}
  ]
}
EOF
  cat >"$TEST_ROOT/runtimes.json" <<'EOF'
{
  "runtimes": [
    {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","name":"iOS 18.0","version":"18.0","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-0","name":"iOS 26.0","version":"26.0","isAvailable":true},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-0","name":"watchOS 26.0","version":"26.0","isAvailable":true}
  ]
}
EOF
}

reset_case() {
  local name=$1
  CASE_ROOT="$TEST_ROOT/$name"
  rm -rf -- "$CASE_ROOT"
  mkdir -p "$CASE_ROOT/state" "$CASE_ROOT/cache"
  printf '{}\n' >"$CASE_ROOT/state/registry.json"
  printf '{"devices":{}}\n' >"$CASE_ROOT/devices.json"
  printf '%s\n' "$CREATED_UUID" >"$CASE_ROOT/next-uuid"
  : >"$CASE_ROOT/gate.log"
  : >"$CASE_ROOT/simctl.log"
  : >"$CASE_ROOT/xcodebuild.log"
  : >"$CASE_ROOT/xcpretty-input.log"

  export IOS_SIM_GATE_HOME="$CASE_ROOT/state"
  export IOS_SIM_GATE_CACHE_HOME="$CASE_ROOT/cache"
  export IOS_SIM_GATE_BIN="$TEST_ROOT/bin/ios-sim-gate"
  export IOS_SIM_GATE_BASH_BIN=/opt/homebrew/bin/bash
  export IOS_SIM_GATE_JQ_BIN="$JQ_BIN"
  export IOS_SIM_GATE_SIMCTL_BIN="$TEST_ROOT/bin/simctl"
  export GATE_LOG="$CASE_ROOT/gate.log"
  export SIMCTL_LOG="$CASE_ROOT/simctl.log"
  export XCODEBUILD_LOG="$CASE_ROOT/xcodebuild.log"
  export XCPRETTY_INPUT_LOG="$CASE_ROOT/xcpretty-input.log"
  export DEVICES_JSON="$CASE_ROOT/devices.json"
  export DEVICE_TYPES_JSON="$TEST_ROOT/device-types.json"
  export RUNTIMES_JSON="$TEST_ROOT/runtimes.json"
  export NEXT_UUID_FILE="$CASE_ROOT/next-uuid"
  export JQ_BIN WINNER_UUID
  unset IOS_SIM_GATE_DEVICE_TYPE IOS_SIM_GATE_RUNTIME SIMULATE_REGISTER_RACE XCODEBUILD_EXIT \
    XCODEBUILD_STDOUT XCODEBUILD_STDERR XCPRETTY_EXIT GATE_STATUS_EXIT INCOMPATIBLE_RUNTIME
}

add_device() {
  local uuid=$1
  local name=$2
  local runtime=$3
  local available=${4:-true}
  local temporary="$DEVICES_JSON.tmp"
  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  "$JQ_BIN" --arg uuid "$uuid" --arg name "$name" --arg runtime "$runtime" \
    --argjson available "$available" '
    .devices[$runtime] = ((.devices[$runtime] // []) + [{
      udid: $uuid,
      name: $name,
      state: "Shutdown",
      isAvailable: $available,
      dataPathSize: 0
    }])
  ' "$DEVICES_JSON" >"$temporary"
  mv "$temporary" "$DEVICES_JSON"
}

set_owner() {
  local uuid=$1
  local agent=$2
  local session=$3
  local temporary="$IOS_SIM_GATE_HOME/registry.json.tmp"
  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  "$JQ_BIN" --arg uuid "$uuid" --arg agent "$agent" --arg session "$session" '
    . + {($uuid): {
      project: "family-foqos",
      agent: $agent,
      session: $session,
      lastupdated: "2026-08-10T00:00:00Z"
    }}
  ' "$IOS_SIM_GATE_HOME/registry.json" >"$temporary"
  mv "$temporary" "$IOS_SIM_GATE_HOME/registry.json"
}

run_wrapper() {
  PATH="$TEST_ROOT/bin:$PATH" "$WRAPPER" "$@"
}

write_fake_gate
write_fake_simctl
write_fake_xcodebuild
write_fake_xcpretty
write_fake_fastlane_dependencies
write_inventory_files

if [[ ! -x "$WRAPPER" ]]; then
  fail "scripts/xcode-stream.sh is missing or not executable"
fi

reset_case exact-reuse
add_device "$OTHER_UUID" "Other owner" com.apple.CoreSimulator.SimRuntime.iOS-26-0
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$OTHER_UUID" build1 collab
set_owner "$REUSE_UUID" build2 collab
run_wrapper --agent build2 --session collab -- xcodebuild test -project FamilyFoqos.xcodeproj
assert_contains "$GATE_LOG" $'run\tfamily-foqos\tbuild2\tcollab\t11111111-1111-1111-1111-111111111111'
assert_not_contains "$SIMCTL_LOG" "create "
assert_contains "$XCODEBUILD_LOG" "platform=iOS Simulator,id=$REUSE_UUID"
assert_contains "$XCODEBUILD_LOG" "$CASE_ROOT/cache/DerivedData/family-foqos/build2/collab"
assert_contains "$XCODEBUILD_LOG" "-parallel-testing-enabled"
assert_contains "$XCODEBUILD_LOG" "NO"
assert_contains "$XCODEBUILD_LOG" "-disable-concurrent-destination-testing"

reset_case session-isolation
add_device "$REUSE_UUID" "No session" com.apple.CoreSimulator.SimRuntime.iOS-26-0
add_device "$SESSION_UUID" "Named session" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 ""
set_owner "$SESSION_UUID" build2 collab
run_wrapper --agent build2 --session collab -- xcodebuild test
assert_contains "$GATE_LOG" "$SESSION_UUID"
assert_not_contains "$GATE_LOG" "$REUSE_UUID"

reset_case no-session-reuse
add_device "$REUSE_UUID" "No session" com.apple.CoreSimulator.SimRuntime.iOS-26-0
add_device "$SESSION_UUID" "Named session" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 ""
set_owner "$SESSION_UUID" build2 collab
run_wrapper --agent build2 -- xcodebuild test
assert_contains "$GATE_LOG" "$REUSE_UUID"
assert_not_contains "$GATE_LOG" "$SESSION_UUID"

reset_case crash-window-orphan
add_device "$OTHER_UUID" "Family Foqos - build2 - orphan" \
  com.apple.CoreSimulator.SimRuntime.iOS-26-0
set +e
orphan_output=$(run_wrapper --agent build2 --session orphan -- xcodebuild test 2>&1)
orphan_status=$?
set -e
if [[ "$orphan_status" -eq 0 || "$orphan_output" != *"display name already exists"* ]]; then
  fail "an unregistered same-name simulator must block allocation: $orphan_output"
fi
assert_not_contains "$SIMCTL_LOG" "create "
assert_not_contains "$SIMCTL_LOG" "delete $OTHER_UUID"

reset_case default-allocation
run_wrapper --agent build2 --session new -- xcodebuild test
assert_contains "$SIMCTL_LOG" \
  "create Family Foqos - build2 - new com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-0"
assert_contains "$GATE_LOG" $'register\tfamily-foqos\tbuild2\tnew\t44444444-4444-4444-4444-444444444444'

reset_case override-allocation
IOS_SIM_GATE_DEVICE_TYPE="iPhone 17 Pro Max" IOS_SIM_GATE_RUNTIME="18.0" \
  run_wrapper --agent build2 --session overrides -- xcodebuild test
assert_contains "$SIMCTL_LOG" \
  "create Family Foqos - build2 - overrides com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-18-0"

reset_case compatible-runtime-fallback
INCOMPATIBLE_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-0 \
  run_wrapper --agent build2 --session fallback -- xcodebuild test
assert_contains "$SIMCTL_LOG" \
  "create Family Foqos - build2 - fallback com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-0"
assert_contains "$SIMCTL_LOG" \
  "create Family Foqos - build2 - fallback com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-18-0"

reset_case explicit-incompatible-runtime
set +e
incompatible_output=$(INCOMPATIBLE_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-0 \
  IOS_SIM_GATE_RUNTIME=26.0 \
  run_wrapper --agent build2 --session incompatible -- xcodebuild test 2>&1)
incompatible_status=$?
set -e
if [[ "$incompatible_status" -eq 0 || "$incompatible_output" != *"incompatible"* ]]; then
  fail "explicit incompatible runtime must fail closed"
fi
assert_not_contains "$GATE_LOG" $'register\tfamily-foqos\tbuild2\tincompatible'

reset_case stale-replacement
add_device "$STALE_UUID" "Unavailable" com.apple.CoreSimulator.SimRuntime.iOS-18-0 false
set_owner "$STALE_UUID" build2 stale
run_wrapper --agent build2 --session stale -- xcodebuild test
assert_contains "$GATE_LOG" $'run\tfamily-foqos\tbuild2\tstale\t66666666-6666-6666-6666-666666666666'
assert_contains "$SIMCTL_LOG" "delete $STALE_UUID"
assert_contains "$GATE_LOG" "reconciled"
assert_contains "$GATE_LOG" $'register\tfamily-foqos\tbuild2\tstale\t44444444-4444-4444-4444-444444444444'

reset_case registration-race
add_device "$WINNER_UUID" "Race winner" com.apple.CoreSimulator.SimRuntime.iOS-26-0
SIMULATE_REGISTER_RACE=1 run_wrapper --agent build2 --session race -- xcodebuild test
assert_contains "$SIMCTL_LOG" "delete $CREATED_UUID"
assert_not_contains "$SIMCTL_LOG" "delete $WINNER_UUID"
assert_contains "$GATE_LOG" $'run\tfamily-foqos\tbuild2\trace\t55555555-5555-5555-5555-555555555555'

reset_case rejected-flags
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 collab
for forbidden in -destination -derivedDataPath -parallel-testing-enabled \
  -disable-concurrent-destination-testing OBJROOT=/tmp/objects SYMROOT=/tmp/symbols \
  BUILD_DIR=/tmp/build -xcconfig; do
  set +e
  output=$(run_wrapper --agent build2 --session collab -- xcodebuild test "$forbidden" bad 2>&1)
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"must not supply $forbidden"* ]]; then
    fail "caller-supplied $forbidden must be rejected"
  fi
done

reset_case rejected-indirect-xcodebuild
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 collab
set +e
output=$(run_wrapper --agent build2 --session collab -- /usr/bin/true xcodebuild test 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 || "$output" != *"xcodebuild must be the command immediately after --"* ]]; then
  fail "a later bare xcodebuild token must be rejected"
fi
run_wrapper --agent build2 --session collab -- /usr/bin/true xcodebuild-wrapper

reset_case exit-status
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 collab
set +e
XCODEBUILD_EXIT=23 run_wrapper --agent build2 --session collab -- xcodebuild test
status=$?
set -e
[[ "$status" -eq 23 ]] || fail "expected xcodebuild exit 23, got $status"

reset_case formatted-preflight-status
set +e
GATE_STATUS_EXIT=29 zsh -f -c '
  export PATH="$1:$PATH"
  "$2" --agent build2 --session collab --xcpretty -- xcodebuild test
' _ "$TEST_ROOT/bin" "$WRAPPER"
status=$?
set -e
[[ "$status" -eq 29 ]] || fail "expected formatted preflight exit 29, got $status"
[[ ! -s "$XCPRETTY_INPUT_LOG" ]] || fail "formatter ran before gate preflight completed"

reset_case formatted-child-status
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 collab
set +e
XCODEBUILD_EXIT=23 XCPRETTY_EXIT=0 \
  run_wrapper --agent build2 --session collab --xcpretty -- xcodebuild test
status=$?
set -e
[[ "$status" -eq 23 ]] || fail "expected formatted xcodebuild exit 23, got $status"

reset_case formatted-formatter-status
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 collab
set +e
XCODEBUILD_EXIT=0 XCPRETTY_EXIT=17 \
  run_wrapper --agent build2 --session collab --xcpretty -- xcodebuild test
status=$?
set -e
[[ "$status" -eq 17 ]] || fail "expected xcpretty exit 17 after xcodebuild success, got $status"

reset_case formatted-merged-output
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 collab
XCODEBUILD_STDOUT="stdout marker" XCODEBUILD_STDERR="stderr marker" \
  run_wrapper --agent build2 --session collab --xcpretty -- xcodebuild test
assert_contains "$XCPRETTY_INPUT_LOG" "stdout marker"
assert_contains "$XCPRETTY_INPUT_LOG" "stderr marker"

reset_case rejected-xcpretty-scope
set +e
output=$(run_wrapper --agent build2 --session collab --xcpretty -- /usr/bin/true 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 || "$output" != *"--xcpretty requires xcodebuild immediately after --"* ]]; then
  fail "--xcpretty must reject a non-xcodebuild child before gate mutation"
fi
[[ ! -s "$GATE_LOG" ]] || fail "invalid --xcpretty use reached the gate"

if [[ ! -x "$ADAPTER" ]]; then
  fail "scripts/ios-sim-gate-bin/xcrun is missing or not executable"
fi

REAL_XCRUN_LOG="$TEST_ROOT/real-xcrun.log"
export REAL_XCRUN_LOG
IOS_SIM_GATE_REAL_XCRUN="$TEST_ROOT/bin/real-xcrun" \
  IOS_SIM_GATE_UDID="$REUSE_UUID" \
  "$ADAPTER" simctl shutdown booted
printf '<simctl>\n<shutdown>\n<%s>\n' "$REUSE_UUID" >"$TEST_ROOT/expected-xcrun.log"
cmp -s "$REAL_XCRUN_LOG" "$TEST_ROOT/expected-xcrun.log" ||
  fail "adapter did not rewrite the exact shutdown-booted invocation"

negative_cases=(
  "simctl|shutdown|$OTHER_UUID"
  "simctl|list|devices"
  "--sdk|iphonesimulator|simctl|shutdown|booted"
  "simctl|spawn|$REUSE_UUID|argument with spaces"
)
for encoded_case in "${negative_cases[@]}"; do
  IFS='|' read -r -a arguments <<<"$encoded_case"
  IOS_SIM_GATE_REAL_XCRUN="$TEST_ROOT/bin/real-xcrun" \
    IOS_SIM_GATE_UDID="$REUSE_UUID" \
    "$ADAPTER" "${arguments[@]}"
  : >"$TEST_ROOT/expected-xcrun.log"
  for argument in "${arguments[@]}"; do
    printf '<%s>\n' "$argument" >>"$TEST_ROOT/expected-xcrun.log"
  done
  cmp -s "$REAL_XCRUN_LOG" "$TEST_ROOT/expected-xcrun.log" ||
    fail "adapter changed negative case: $encoded_case"
done

: >"$REAL_XCRUN_LOG"
set +e
missing_uuid_output=$(IOS_SIM_GATE_REAL_XCRUN="$TEST_ROOT/bin/real-xcrun" \
  "$ADAPTER" simctl shutdown booted 2>&1)
missing_uuid_status=$?
set -e
if [[ "$missing_uuid_status" -eq 0 || "$missing_uuid_output" != *"IOS_SIM_GATE_UDID"* ]]; then
  fail "adapter must fail closed when the exact rewrite lacks a gate UUID"
fi
[[ ! -s "$REAL_XCRUN_LOG" ]] || fail "adapter called real xcrun after missing-UUID failure"

reset_case screenshot-path-scope
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 screenshots
FASTLANE_ENTRY_PATH_LOG="$CASE_ROOT/fastlane-entry-path.log"
FASTLANE_CHILD_PATH_LOG="$CASE_ROOT/fastlane-child-path.log"
FASTLANE_ARGS_LOG="$CASE_ROOT/fastlane-args.log"
FAKE_RUBY_PREFIX="$TEST_ROOT/ruby"
export FASTLANE_ENTRY_PATH_LOG FASTLANE_CHILD_PATH_LOG FASTLANE_ARGS_LOG FAKE_RUBY_PREFIX
set +e
output=$(run_wrapper --agent build2 --session screenshots -- \
  "$REPO_ROOT/scripts/fastlane.sh" screenshots xcodebuild 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 || "$output" != *"xcodebuild must be the command immediately after --"* ]]; then
  fail "the screenshot branch must not bypass later-token xcodebuild rejection"
fi
caller_path=$PATH
run_wrapper --agent build2 --session screenshots -- "$REPO_ROOT/scripts/fastlane.sh" screenshots
[[ "$PATH" == "$caller_path" ]] || fail "screenshot wrapper changed the caller PATH"
entry_path=$(<"$FASTLANE_ENTRY_PATH_LOG")
[[ "$entry_path" == "$REPO_ROOT/scripts/ios-sim-gate-bin:"* ]] ||
  fail "adapter PATH was not scoped to the screenshot lane process"
assert_contains "$FASTLANE_ARGS_LOG" "screenshots"

reset_case non-screenshot-adapter-scope
add_device "$REUSE_UUID" "Family Foqos build2" com.apple.CoreSimulator.SimRuntime.iOS-26-0
set_owner "$REUSE_UUID" build2 bundle-exec
FASTLANE_CHILD_PATH_LOG="$CASE_ROOT/bundle-child-path.log"
FASTLANE_ARGS_LOG="$CASE_ROOT/bundle-args.log"
export FASTLANE_CHILD_PATH_LOG FASTLANE_ARGS_LOG
run_wrapper --agent build2 --session bundle-exec -- \
  "$TEST_ROOT/ruby/bin/bundle" exec ruby -v
bundle_child_path=$(<"$FASTLANE_CHILD_PATH_LOG")
[[ "$bundle_child_path" == "$REPO_ROOT/scripts/ios-sim-gate-bin:"* ]] ||
  fail "adapter PATH was not installed for a non-screenshot bundle exec child"
assert_contains "$FASTLANE_ARGS_LOG" "exec"

POLICY_FILE="$REPO_ROOT/AGENTS.md"
policy_requirements=(
  "up to three"
  "Xcode/simulator streams"
  "scripts/xcode-stream.sh --agent"
  "UUID destinations only"
  "-parallel-testing-enabled NO"
  "-disable-concurrent-destination-testing"
  "scripts/fastlane.sh screenshots"
  "scripts/clean-build.sh"
  "Read-only work does not consume a gate slot"
  "Archive and upload lanes do not boot simulators"
)
for requirement in "${policy_requirements[@]}"; do
  assert_contains "$POLICY_FILE" "$requirement"
done
assert_not_contains "$POLICY_FILE" "NO parallel development on the same machine"
if grep -nE '^xcodebuild ' "$POLICY_FILE" >/dev/null; then
  fail "AGENTS.md still documents a raw xcodebuild entrypoint"
else
  grep_status=$?
  [[ "$grep_status" -eq 1 ]] || fail "could not inspect AGENTS.md (grep exit $grep_status)"
fi

echo "PASS: xcode stream allocation, enforcement, adapter scoping, and exact exit propagation"
