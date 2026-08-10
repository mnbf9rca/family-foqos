#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check-cloudkit-schema-export.sh"
TEST_ROOT=$(mktemp -d)

cleanup() {
  if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

if [[ ! -f "$CHECK_SCRIPT" ]]; then
  echo "FAIL: CloudKit schema export checker is missing"
  exit 1
fi

mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/fastlane" "$TEST_ROOT/Foqos/CloudKit"
cp "$CHECK_SCRIPT" "$TEST_ROOT/scripts/check-cloudkit-schema-export.sh"

run_check() {
  set +e
  CHECK_OUTPUT=$(cd "$TEST_ROOT" && bash scripts/check-cloudkit-schema-export.sh 2>&1)
  CHECK_STATUS=$?
  set -e
}

printf '%s\n' \
  '# Required record types' \
  'RECORD TYPE Required' \
  'RECORD TYPE Required.requiredField' \
  'RECORD TYPE "cloudkit.share"' \
  >"$TEST_ROOT/fastlane/required-prod-schema.txt"
printf '%s\n' \
  'DEFINE SCHEMA' \
  'RECORD TYPE Required (' \
  '  requiredField STRING' \
  ');' \
  'RECORD TYPE "cloudkit.share" (' \
  ');' \
  'RECORD TYPE DeprecatedExtra (' \
  ');' \
  >"$TEST_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb"
run_check
if [[ "$CHECK_STATUS" -ne 0 || "$CHECK_OUTPUT" != *"covers every required record type"* ]]; then
  echo "FAIL: matching schema with compatibility extras must pass"
  echo "$CHECK_OUTPUT"
  exit 1
fi

printf '%s\n' \
  'DEFINE SCHEMA' \
  'RECORD TYPE Required (' \
  ');' \
  'RECORD TYPE "cloudkit.share" (' \
  ');' \
  >"$TEST_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb"
run_check
if [[ "$CHECK_STATUS" -ne 1 || "$CHECK_OUTPUT" != *"MISSING from checked-in CloudKit schema: RECORD TYPE Required.requiredField"* ]]; then
  echo "FAIL: missing required field must exit 1"
  echo "$CHECK_OUTPUT"
  exit 1
fi

printf '%s\n' 'DEFINE SCHEMA' 'RECORD TYPE Other (' ');' \
  >"$TEST_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb"
run_check
if [[ "$CHECK_STATUS" -ne 1 || "$CHECK_OUTPUT" != *"MISSING from checked-in CloudKit schema: RECORD TYPE Required"* ]]; then
  echo "FAIL: missing required record type must exit 1"
  echo "$CHECK_OUTPUT"
  exit 1
fi

printf '%s\n' \
  'DEFINE SCHEMA' \
  'RECORD TYPE RequiredExtra (' \
  ');' \
  'RECORD TYPE "cloudkit.share" (' \
  ');' \
  >"$TEST_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb"
run_check
if [[ "$CHECK_STATUS" -ne 1 || "$CHECK_OUTPUT" != *"MISSING from checked-in CloudKit schema: RECORD TYPE Required"* ]]; then
  echo "FAIL: a prefixed record type must not satisfy an exact requirement"
  echo "$CHECK_OUTPUT"
  exit 1
fi

printf '%s\n' '# comments do not count' '' >"$TEST_ROOT/fastlane/required-prod-schema.txt"
run_check
if [[ "$CHECK_STATUS" -ne 2 || "$CHECK_OUTPUT" != *"empty or unreadable"* ]]; then
  echo "FAIL: comment-only manifest must exit 2"
  echo "$CHECK_OUTPUT"
  exit 1
fi

echo "PASS: checked-in CloudKit schema gate cases"
