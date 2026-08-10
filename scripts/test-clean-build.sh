#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLEAN_SCRIPT="$REPO_ROOT/scripts/clean-build.sh"
TEST_ROOT=$(mktemp -d)
FAKE_HOME="$TEST_ROOT/home"
GATE_ROOT="$FAKE_HOME/Library/Caches/ios-sim-gate/DerivedData/family-foqos"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$GATE_ROOT/build2/session-a" "$GATE_ROOT/build2/session-b"
touch "$GATE_ROOT/build2/session-a/owned" "$GATE_ROOT/build2/session-b/sibling"

HOME="$FAKE_HOME" IOS_SIM_GATE_DERIVED_DATA_PATH="$GATE_ROOT/build2/session-a" \
  "$CLEAN_SCRIPT"
[[ ! -e "$GATE_ROOT/build2/session-a" ]] || fail "exact owner DerivedData was not removed"
[[ -f "$GATE_ROOT/build2/session-b/sibling" ]] || fail "sibling DerivedData was removed"

CUSTOM_CACHE_ROOT="$TEST_ROOT/custom-gate-cache"
CUSTOM_PROJECT_ROOT="$CUSTOM_CACHE_ROOT/DerivedData/family-foqos"
mkdir -p "$CUSTOM_PROJECT_ROOT/build3/session-custom" \
  "$CUSTOM_PROJECT_ROOT/build3/session-sibling"
touch "$CUSTOM_PROJECT_ROOT/build3/session-custom/owned" \
  "$CUSTOM_PROJECT_ROOT/build3/session-sibling/sibling"
HOME="$FAKE_HOME" IOS_SIM_GATE_CACHE_HOME="$CUSTOM_CACHE_ROOT" \
  IOS_SIM_GATE_DERIVED_DATA_PATH="$CUSTOM_PROJECT_ROOT/build3/session-custom" \
  "$CLEAN_SCRIPT"
[[ ! -e "$CUSTOM_PROJECT_ROOT/build3/session-custom" ]] ||
  fail "custom-cache owner DerivedData was not removed"
[[ -f "$CUSTOM_PROJECT_ROOT/build3/session-sibling/sibling" ]] ||
  fail "custom-cache sibling DerivedData was removed"

assert_refused() {
  local description=$1
  local target=${2-__unset__}
  local output
  local status

  mkdir -p "$GATE_ROOT/build2/session-b"
  touch "$GATE_ROOT/build2/session-b/sibling"
  set +e
  if [[ "$target" == "__unset__" ]]; then
    output=$(env -u IOS_SIM_GATE_DERIVED_DATA_PATH HOME="$FAKE_HOME" "$CLEAN_SCRIPT" 2>&1)
    status=$?
  else
    output=$(HOME="$FAKE_HOME" IOS_SIM_GATE_DERIVED_DATA_PATH="$target" "$CLEAN_SCRIPT" 2>&1)
    status=$?
  fi
  set -e

  [[ "$status" -ne 0 ]] || fail "$description target was accepted"
  [[ "$output" == *"refusing"* || "$output" == *"requires"* ]] ||
    fail "$description failure was not explicit: $output"
  [[ -f "$GATE_ROOT/build2/session-b/sibling" ]] ||
    fail "$description failure removed sibling DerivedData"
}

assert_refused "unset"
assert_refused "relative" "relative/DerivedData"
assert_refused "gate project root" "$GATE_ROOT"
assert_refused "wrong project" \
  "$FAKE_HOME/Library/Caches/ios-sim-gate/DerivedData/other-project/build2/session-b"
assert_refused "traversal-like" "$GATE_ROOT/build2/session-b/../../other-project/owned"

echo "PASS: clean-build deletes only exact gate-owned Family Foqos DerivedData"
