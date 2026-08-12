#!/usr/bin/env bash
set -euo pipefail

required_commands=(cp dirname mktemp rm sed)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "FAIL: required command not found: $required_command" >&2
    exit 127
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORTER="$REPO_ROOT/scripts/report-cloudkit-schema-drift.sh"
TEST_ROOT=$(mktemp -d)
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

[[ -x "$REPORTER" ]] || { echo "FAIL: schema drift reporter is missing"; exit 1; }

REAL_OUTPUT=$("$REPORTER")
[[ "$REAL_OUTPUT" == 'OK: no CloudKit schema drift.' ]] || {
  echo "FAIL: real repository must have no schema drift"
  echo "$REAL_OUTPUT"
  exit 1
}

FIXTURE_ROOT="$TEST_ROOT/repo"
mkdir -p "$FIXTURE_ROOT"
cp -R \
  "$REPO_ROOT/Foqos" \
  "$REPO_ROOT/FoqosDeviceMonitor" \
  "$REPO_ROOT/FoqosShieldConfig" \
  "$REPO_ROOT/FoqosWidget" \
  "$REPO_ROOT/fastlane" \
  "$FIXTURE_ROOT/"

sed '/case profileSchemaVersion/a\
    case smokeTestField
' \
  "$FIXTURE_ROOT/Foqos/CloudKit/SyncModels.swift" >"$TEST_ROOT/SyncModels.swift"
cp "$TEST_ROOT/SyncModels.swift" "$FIXTURE_ROOT/Foqos/CloudKit/SyncModels.swift"

set +e
DRIFT_OUTPUT=$(CLOUDKIT_SCHEMA_REPO_ROOT="$FIXTURE_ROOT" "$REPORTER" 2>&1)
DRIFT_STATUS=$?
set -e
if [[ "$DRIFT_STATUS" -ne 1 ||
  "$DRIFT_OUTPUT" != *"MISSING from manifest: RECORD TYPE SyncedProfile.smokeTestField"* ||
  "$DRIFT_OUTPUT" != *"CloudKit schema drift detected."* ]]; then
  echo "FAIL: fake field must be reported as manifest drift"
  printf 'exit: %s\n%s\n' "$DRIFT_STATUS" "$DRIFT_OUTPUT"
  exit 1
fi

echo "PASS: CloudKit schema drift smoke test"
