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

simctl() {
  if [[ -n "${IOS_SIM_GATE_SIMCTL_BIN:-}" ]]; then
    "$IOS_SIM_GATE_SIMCTL_BIN" "$@"
  else
    /usr/bin/xcrun simctl "$@"
  fi
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
  local use_xcpretty=$1
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

  if [[ "$use_xcpretty" == true ]]; then
    local -a pipeline_statuses
    set +e
    "$@" \
      -destination "$IOS_SIM_GATE_DESTINATION" \
      -derivedDataPath "$IOS_SIM_GATE_DERIVED_DATA_PATH" \
      -parallel-testing-enabled NO \
      -disable-concurrent-destination-testing \
      2>&1 | bundle exec xcpretty
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
    use_xcpretty=false
    if [[ "${1:-}" == "--xcpretty" ]]; then
      use_xcpretty=true
      shift
    fi
    execute_internal "$use_xcpretty" "$@"
    ;;
  __delete)
    shift
    delete_internal "$@"
    exit 0
    ;;
esac

usage() {
  cat >&2 <<'EOF'
Usage: scripts/xcode-stream.sh --agent NAME [--session NAME] [--xcpretty] -- COMMAND [ARG ...]
EOF
  exit 2
}

agent=""
session=""
use_xcpretty=false
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
    --xcpretty)
      use_xcpretty=true
      shift
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
[[ "$use_xcpretty" != true || "${command[0]##*/}" == "xcodebuild" ]] ||
  die "--xcpretty requires xcodebuild immediately after --"
if [[ "$use_xcpretty" == true ]]; then
  command -v bundle >/dev/null || die "bundle not found; --xcpretty requires bundle exec xcpretty"
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
[[ "$use_xcpretty" != true ]] || internal_command+=(--xcpretty)
internal_command+=(-- "${command[@]}")

exec "$BASH4_BIN" "$GATE_BIN" run "${owner_args[@]}" --udid "$owned_uuid" -- \
  "${internal_command[@]}"
