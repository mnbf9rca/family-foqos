#!/bin/bash

BASH4_BIN="${IOS_SIM_GATE_BASH_BIN:-/opt/homebrew/bin/bash}"
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  if [[ ! -x "$BASH4_BIN" ]]; then
    echo "xcode-stream: Bash 4+ is required; expected $BASH4_BIN" >&2
    exit 127
  fi
  exec "$BASH4_BIN" "$0" "$@"
fi

set -euo pipefail

PROJECT=family-foqos
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$REPO_ROOT/scripts/xcode-stream.sh"
GATE_BIN="${IOS_SIM_GATE_BIN:-$HOME/.local/bin/ios-sim-gate}"
JQ_BIN="${IOS_SIM_GATE_JQ_BIN:-/opt/homebrew/bin/jq}"
STATE_ROOT="${IOS_SIM_GATE_HOME:-$HOME/Library/Application Support/ios-sim-gate}"
REGISTRY="$STATE_ROOT/registry.json"
XCTEST_DEVICES_ROOT="${IOS_SIM_GATE_XCTEST_DEVICES_ROOT:-$HOME/Library/Developer/XCTestDevices}"
DEFAULT_DEVICE_TYPE="iPhone 17"

die() {
  echo "xcode-stream: $*" >&2
  exit 1
}

validate_identifier() {
  local label=$1
  local value=$2
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    die "invalid $label: $value"
}

validate_uuid() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
    die "invalid simulator UUID: $1"
}

is_shell_command() {
  case "${1##*/}" in
    sh|bash|zsh) return 0 ;;
    *) return 1 ;;
  esac
}

reject_shell_mediated_xcodebuild() {
  local arguments=("$@")
  local shell_index=-1
  local index

  if is_shell_command "${arguments[0]}"; then
    shell_index=0
  elif [[ "${arguments[0]##*/}" == env ]]; then
    for ((index = 1; index < ${#arguments[@]}; index++)); do
      if [[ "${arguments[index]}" != *=* ]] && is_shell_command "${arguments[index]}"; then
        shell_index=$index
        break
      fi
    done
  fi
  ((shell_index >= 0)) || return 0

  for ((index = shell_index + 1; index + 1 < ${#arguments[@]}; index++)); do
    [[ "${arguments[index]}" =~ ^-[[:alpha:]]*c[[:alpha:]]*$ ]] || continue
    if [[ "${arguments[index + 1]}" =~ (^|[^[:alnum:]_])xcodebuild([^[:alnum:]_-]|$) ]]; then
      die "AGENTS.md requires xcodebuild immediately after --; shell-mediated xcodebuild is prohibited"
    fi
    return 0
  done
}

simctl() {
  if [[ -n "${IOS_SIM_GATE_SIMCTL_BIN:-}" ]]; then
    "$IOS_SIM_GATE_SIMCTL_BIN" "$@"
  else
    /usr/bin/xcrun simctl "$@"
  fi
}

xctest_devices_census() {
  local inventory
  local census

  if [[ ! -d "$XCTEST_DEVICES_ROOT" ]]; then
    echo "xcode-stream: XCTestDevices census failed: root not found: $XCTEST_DEVICES_ROOT" >&2
    return 1
  fi
  if ! inventory=$(simctl --set "$XCTEST_DEVICES_ROOT" list devices --json 2>/dev/null); then
    echo "xcode-stream: XCTestDevices census failed: simctl could not list $XCTEST_DEVICES_ROOT" >&2
    return 1
  fi
  if ! census=$("$JQ_BIN" -ce '
    if (type != "object") or ((.devices | type) != "object") then
      error("inventory must contain a devices object")
    elif (all(
      .devices | to_entries[];
      if (.value | type) != "array" then
        false
      else
        all(.value[]; ((.udid | type) == "string") and ((.name | type) == "string"))
      end
    ) | not) then
      error("every device must contain string udid and name fields")
    else
      [.devices | to_entries[] | .value[] | {udid, name}] | sort_by(.udid)
    end
  ' <<<"$inventory"); then
    echo "xcode-stream: XCTestDevices census failed: invalid simctl inventory" >&2
    return 1
  fi

  printf '%s\n' "$census"
}

# shellcheck disable=SC2329 # Invoked from the EXIT-trap finalizer.
new_xctest_devices() {
  local before=$1
  local after=$2

  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  "$JQ_BIN" -cn --argjson before "$before" --argjson after "$after" '
    [
      $after[] |
      . as $device |
      select(any($before[]; .udid == $device.udid) | not)
    ]
  '
}

# shellcheck disable=SC2329 # Installed as the EXIT trap below.
finish_xctest_devices_census() {
  local child_status=$?
  trap - EXIT INT TERM
  set +e

  local after
  local added
  local owned_growth
  local unattributed_growth
  if ! after=$(xctest_devices_census); then
    echo "xcode-stream: XCTestDevices census failed after gated child; refusing to pass" >&2
    exit 1
  fi
  if ! added=$(new_xctest_devices "$xctest_devices_before" "$after"); then
    echo "xcode-stream: XCTestDevices census failed while comparing inventories" >&2
    exit 1
  fi
  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  if ! owned_growth=$("$JQ_BIN" -c --arg owner "$IOS_SIM_GATE_DEVICE_NAME" \
    '[.[] | select((.name == $owner) or (.name | endswith(" of " + $owner)))]' <<<"$added"); then
    echo "xcode-stream: XCTestDevices census failed while attributing growth" >&2
    exit 1
  fi
  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  if ! unattributed_growth=$("$JQ_BIN" -c --arg owner "$IOS_SIM_GATE_DEVICE_NAME" \
    '[.[] | select(((.name == $owner) or (.name | endswith(" of " + $owner))) | not)]' \
    <<<"$added"); then
    echo "xcode-stream: XCTestDevices census failed while classifying growth" >&2
    exit 1
  fi

  if [[ "$unattributed_growth" != "[]" ]]; then
    echo "xcode-stream: WARNING: XCTestDevices grew during gated run without attributable owner match: $unattributed_growth" >&2
  fi
  if [[ "$owned_growth" != "[]" ]]; then
    echo "xcode-stream: XCTestDevices clone appeared for owned simulator $IOS_SIM_GATE_DEVICE_NAME: $owned_growth" >&2
    exit 1
  fi

  exit "$child_status"
}

gate() {
  "$BASH4_BIN" "$GATE_BIN" "$@"
}

require_internal_gate_contract() {
  [[ "${IOS_SIM_GATE_PROJECT:-}" == "$PROJECT" ]] ||
    die "internal execution requires IOS_SIM_GATE_PROJECT=$PROJECT"
  [[ -n "${IOS_SIM_GATE_AGENT:-}" ]] || die "internal execution requires IOS_SIM_GATE_AGENT"
  [[ -n "${IOS_SIM_GATE_UDID:-}" ]] || die "internal execution requires IOS_SIM_GATE_UDID"
  [[ -n "${IOS_SIM_GATE_DESTINATION:-}" ]] ||
    die "internal execution requires IOS_SIM_GATE_DESTINATION"
  [[ -n "${IOS_SIM_GATE_DERIVED_DATA_PATH:-}" ]] ||
    die "internal execution requires IOS_SIM_GATE_DERIVED_DATA_PATH"
  validate_uuid "$IOS_SIM_GATE_UDID"
  [[ "$IOS_SIM_GATE_DESTINATION" == "platform=iOS Simulator,id=$IOS_SIM_GATE_UDID" ]] ||
    die "gate destination does not match gate UUID"
}

execute_internal() {
  local use_xcbeautify=$1
  shift
  [[ "${1:-}" == "--" ]] || die "internal execution requires -- before the command"
  shift
  (($#)) || die "internal execution requires a command"
  require_internal_gate_contract

  export PATH="$REPO_ROOT/scripts/ios-sim-gate-bin:$PATH"

  local command_name=${1##*/}
  local command_path=""
  local arguments=("$@")
  local index
  if [[ "$1" == */* && -e "$1" ]]; then
    command_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  fi
  for ((index = 1; index < ${#arguments[@]}; index++)); do
    [[ "${arguments[index]}" != "xcodebuild" ]] ||
      die "xcodebuild must be the command immediately after --"
  done
  if [[ "$command_path" == "$REPO_ROOT/scripts/fastlane.sh" && "${2:-}" == "screenshots" ]]; then
    [[ -n "${IOS_SIM_GATE_DEVICE_NAME:-}" ]] ||
      die "screenshot execution requires IOS_SIM_GATE_DEVICE_NAME"
    [[ -n "${IOS_SIM_GATE_RUNTIME_VERSION:-}" ]] ||
      die "screenshot execution requires IOS_SIM_GATE_RUNTIME_VERSION"
    exec "$@"
  fi
  if [[ "$command_name" != "xcodebuild" ]]; then
    exec "$@"
  fi

  local argument
  for argument in "$@"; do
    case "$argument" in
      -destination|-destination=*|-derivedDataPath|-derivedDataPath=*|\
      -parallel-testing-enabled|-parallel-testing-enabled=*|\
      -disable-concurrent-destination-testing|-disable-concurrent-destination-testing=*|\
      OBJROOT=*|SYMROOT=*|BUILD_DIR=*|-xcconfig|-xcconfig=*)
        die "callers must not supply $argument; xcode-stream injects simulator isolation flags"
        ;;
    esac
  done

  if [[ "$use_xcbeautify" == true ]]; then
    local -a pipeline_statuses
    set +e
    "$@" \
      -destination "$IOS_SIM_GATE_DESTINATION" \
      -derivedDataPath "$IOS_SIM_GATE_DERIVED_DATA_PATH" \
      -parallel-testing-enabled NO \
      -disable-concurrent-destination-testing \
      2>&1 | xcbeautify
    pipeline_statuses=("${PIPESTATUS[@]}")
    set -e
    ((pipeline_statuses[0] == 0)) || exit "${pipeline_statuses[0]}"
    exit "${pipeline_statuses[1]}"
  fi

  exec "$@" \
    -destination "$IOS_SIM_GATE_DESTINATION" \
    -derivedDataPath "$IOS_SIM_GATE_DERIVED_DATA_PATH" \
    -parallel-testing-enabled NO \
    -disable-concurrent-destination-testing
}

delete_internal() {
  [[ "$#" -eq 1 ]] || die "internal delete requires one UUID"
  require_internal_gate_contract
  validate_uuid "$1"
  [[ "$1" == "$IOS_SIM_GATE_UDID" ]] || die "internal delete UUID does not match gate UUID"
  simctl shutdown "$1" >/dev/null 2>&1 || true
  simctl delete "$1" >/dev/null
}

case "${1:-}" in
  __execute)
    shift
    use_xcbeautify=false
    if [[ "${1:-}" == "--xcbeautify" ]]; then
      use_xcbeautify=true
      shift
    fi
    execute_internal "$use_xcbeautify" "$@"
    ;;
  __delete)
    shift
    delete_internal "$@"
    exit 0
    ;;
esac

usage() {
  cat >&2 <<'EOF'
Usage: scripts/xcode-stream.sh --agent NAME [--session NAME] [--xcbeautify] -- COMMAND [ARG ...]
EOF
  exit 2
}

agent=""
session=""
use_xcbeautify=false
while (($#)); do
  case "$1" in
    --agent)
      (($# >= 2)) || usage
      agent=$2
      shift 2
      ;;
    --session)
      (($# >= 2)) || usage
      session=$2
      shift 2
      ;;
    --xcbeautify)
      use_xcbeautify=true
      shift
      ;;
    --xcpretty)
      die "--xcpretty was removed; use --xcbeautify"
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$agent" ]] || usage
(($#)) || usage
validate_identifier agent "$agent"
[[ -z "$session" ]] || validate_identifier session "$session"
[[ -x "$BASH4_BIN" ]] || die "Bash 4+ executable not found: $BASH4_BIN"
[[ -f "$GATE_BIN" ]] || die "ios-sim-gate not found: $GATE_BIN"
[[ -x "$JQ_BIN" ]] || die "jq not found: $JQ_BIN"
if [[ -n "${IOS_SIM_GATE_SIMCTL_BIN:-}" ]]; then
  [[ -x "$IOS_SIM_GATE_SIMCTL_BIN" ]] || die "simctl adapter not executable: $IOS_SIM_GATE_SIMCTL_BIN"
else
  [[ -x /usr/bin/xcrun ]] || die "xcrun not found: /usr/bin/xcrun"
fi

command=("$@")
reject_shell_mediated_xcodebuild "${command[@]}"
[[ "$use_xcbeautify" != true || "${command[0]##*/}" == "xcodebuild" ]] ||
  die "--xcbeautify requires xcodebuild immediately after --"
if [[ "$use_xcbeautify" == true ]]; then
  command -v xcbeautify >/dev/null || {
    echo "xcode-stream: xcbeautify not found; install it with: brew install xcbeautify" >&2
    exit 127
  }
  xcbeautify --version >/dev/null 2>&1 ||
    die "xcbeautify unavailable; reinstall it with: brew install xcbeautify"
fi
owner_args=(--project "$PROJECT" --agent "$agent")
if [[ -n "$session" ]]; then
  owner_args+=(--session "$session")
fi

gate status >/dev/null
[[ -f "$REGISTRY" ]] || die "gate registry was not initialized: $REGISTRY"

lookup_owned_uuid() {
  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  "$JQ_BIN" -r \
    --arg project "$PROJECT" \
    --arg agent "$agent" \
    --arg session "$session" '
      first(
        to_entries[] |
        select(
          .value.project == $project and
          .value.agent == $agent and
          (.value.session // "") == $session
        ) |
        .key
      ) // ""
    ' "$REGISTRY"
}

available_inventory=$(simctl list devices available --json)
runtimes_inventory=$(simctl list runtimes available --json)

device_metadata() {
  local uuid=$1
  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  "$JQ_BIN" -rn \
    --arg uuid "$uuid" \
    --argjson devices "$available_inventory" \
    --argjson runtimes "$runtimes_inventory" '
      first(
        $devices.devices | to_entries[] |
        .key as $runtime |
        .value[] |
        select(.udid == $uuid and ((.isAvailable // true) == true)) |
        . as $device |
        ($runtimes.runtimes[] | select(.identifier == $runtime)) as $runtime_record |
        [$device.name, $runtime_record.version] | @tsv
      ) // ""
    '
}

owned_uuid=$(lookup_owned_uuid)
metadata=""
if [[ -n "$owned_uuid" ]]; then
  validate_uuid "$owned_uuid"
  metadata=$(device_metadata "$owned_uuid")
fi

if [[ -n "$owned_uuid" && -z "$metadata" ]]; then
  delete_status=0
  gate run "${owner_args[@]}" --udid "$owned_uuid" -- \
    "$BASH4_BIN" "$SELF" __delete "$owned_uuid" || delete_status=$?
  gate reconcile >/dev/null
  remaining_uuid=$(lookup_owned_uuid)
  if [[ -n "$remaining_uuid" ]]; then
    die "unusable simulator $owned_uuid remains registered after gated delete (status $delete_status)"
  fi
  owned_uuid=""
fi

resolve_device_type() {
  local selector=$1
  local inventory
  inventory=$(simctl list devicetypes --json)
  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  "$JQ_BIN" -r --arg selector "$selector" '
    first(
      .devicetypes[] |
      select(.identifier == $selector or .name == $selector) |
      .identifier
    ) // ""
  ' <<<"$inventory"
}

runtime_candidates() {
  local selector=$1
  # shellcheck disable=SC2016 # jq expressions intentionally use jq variables.
  "$JQ_BIN" -r --arg selector "$selector" '
    .runtimes |
    map(select(
      (.isAvailable // false) == true and
      (.identifier | startswith("com.apple.CoreSimulator.SimRuntime.iOS-")) and
      ($selector == "" or .identifier == $selector or .name == $selector or .version == $selector)
    )) |
    sort_by(.version | split(".") | map(tonumber)) |
    reverse[] |
    [.identifier, .version] | @tsv
  ' <<<"$runtimes_inventory"
}

if [[ -z "$owned_uuid" ]]; then
  device_selector="${IOS_SIM_GATE_DEVICE_TYPE:-$DEFAULT_DEVICE_TYPE}"
  runtime_selector="${IOS_SIM_GATE_RUNTIME:-}"
  device_type=$(resolve_device_type "$device_selector")
  [[ -n "$device_type" ]] || die "no available simulator device type matches: $device_selector"

  display_name="Family Foqos - $agent${session:+ - $session}"
  all_devices_inventory=$(simctl list devices --json)
  # shellcheck disable=SC2016 # jq expression intentionally uses a jq variable.
  conflicting_uuid=$("$JQ_BIN" -r --arg display_name "$display_name" '
    first(.devices[]?[]? | select(.name == $display_name) | .udid) // ""
  ' <<<"$all_devices_inventory")
  [[ -z "$conflicting_uuid" ]] ||
    die "simulator display name already exists outside exact gate ownership: $display_name ($conflicting_uuid)"

  created_uuid=""
  created_runtime_version=""
  candidate_count=0
  while IFS=$'\t' read -r runtime_id runtime_version; do
    [[ -n "$runtime_id" ]] || continue
    ((candidate_count += 1))
    create_status=0
    created_uuid=$(simctl create "$display_name" "$device_type" "$runtime_id") || create_status=$?
    if [[ "$create_status" -eq 0 && -n "$created_uuid" ]]; then
      validate_uuid "$created_uuid"
      created_runtime_version=$runtime_version
      break
    fi
    created_uuid=""
    if [[ -n "$runtime_selector" ]]; then
      die "device type $device_selector is incompatible with runtime $runtime_selector"
    fi
  done < <(runtime_candidates "$runtime_selector")

  ((candidate_count > 0)) || die "no available iOS runtime matches: ${runtime_selector:-newest}"
  [[ -n "$created_uuid" ]] ||
    die "could not create $device_selector on any compatible installed iOS runtime"

  register_output=""
  register_status=0
  register_output=$(gate register "${owner_args[@]}" --udid "$created_uuid" 2>&1) ||
    register_status=$?
  if [[ "$register_status" -eq 0 ]]; then
    owned_uuid=$created_uuid
    metadata=$(printf '%s\t%s\n' "$display_name" "$created_runtime_version")
  else
    simctl shutdown "$created_uuid" >/dev/null 2>&1 || true
    simctl delete "$created_uuid" >/dev/null || true
    owned_uuid=$(lookup_owned_uuid)
    if [[ -n "$owned_uuid" ]]; then
      validate_uuid "$owned_uuid"
      available_inventory=$(simctl list devices available --json)
      metadata=$(device_metadata "$owned_uuid")
    fi
    if [[ -z "$owned_uuid" || -z "$metadata" ]]; then
      [[ -z "$register_output" ]] || echo "$register_output" >&2
      exit "$register_status"
    fi
  fi
fi

[[ -n "$metadata" ]] || die "could not resolve metadata for simulator $owned_uuid"
IFS=$'\t' read -r IOS_SIM_GATE_DEVICE_NAME IOS_SIM_GATE_RUNTIME_VERSION <<<"$metadata"
[[ -n "$IOS_SIM_GATE_DEVICE_NAME" ]] || die "resolved simulator has no display name"
[[ -n "$IOS_SIM_GATE_RUNTIME_VERSION" ]] || die "resolved simulator has no runtime version"
export IOS_SIM_GATE_DEVICE_NAME IOS_SIM_GATE_RUNTIME_VERSION

internal_command=("$BASH4_BIN" "$SELF" __execute)
[[ "$use_xcbeautify" != true ]] || internal_command+=(--xcbeautify)
internal_command+=(-- "${command[@]}")

if ! xctest_devices_before=$(xctest_devices_census); then
  die "XCTestDevices census failed before gated child"
fi
export IOS_SIM_GATE_CENSUS_PARENT_PID=$BASHPID
trap 'exit 130' INT
trap 'exit 143' TERM
trap finish_xctest_devices_census EXIT

set +e
"$BASH4_BIN" "$GATE_BIN" run "${owner_args[@]}" --udid "$owned_uuid" -- \
  "${internal_command[@]}"
child_status=$?
set -e
exit "$child_status"
