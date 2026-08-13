#!/usr/bin/env bash
set -euo pipefail

required_commands=(cp dirname mkdir mktemp rm sed)
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
reset_fixture() {
  rm -rf -- "$FIXTURE_ROOT"
  mkdir -p "$FIXTURE_ROOT"
  cp -R \
    "$REPO_ROOT/Foqos" \
    "$REPO_ROOT/FoqosDeviceMonitor" \
    "$REPO_ROOT/FoqosShieldConfig" \
    "$REPO_ROOT/FoqosWidget" \
    "$REPO_ROOT/fastlane" \
    "$FIXTURE_ROOT/"
}

assert_drift() {
  local expected_line=$1
  local description=$2
  local drift_output
  local drift_status

  set +e
  drift_output=$(CLOUDKIT_SCHEMA_REPO_ROOT="$FIXTURE_ROOT" "$REPORTER" 2>&1)
  drift_status=$?
  set -e
  if [[ "$drift_status" -ne 1 ||
    "$drift_output" != *"$expected_line"* ||
    "$drift_output" != *"CloudKit schema drift detected."* ]]; then
    echo "FAIL: $description"
    printf 'exit: %s\n%s\n' "$drift_status" "$drift_output"
    exit 1
  fi
}

# FieldKey enum discovery.
reset_fixture
sed '/case profileSchemaVersion/a\
    case smokeTestField
' \
  "$FIXTURE_ROOT/Foqos/CloudKit/SyncModels.swift" >"$TEST_ROOT/SyncModels.swift"
cp "$TEST_ROOT/SyncModels.swift" "$FIXTURE_ROOT/Foqos/CloudKit/SyncModels.swift"
assert_drift \
  'MISSING from manifest: RECORD TYPE SyncedProfile.smokeTestField' \
  'FieldKey discovery must report a fake field'

# Static recordType discovery.
reset_fixture
sed '/\/\/ MARK: - SyncedSession (Legacy)/i\
enum SmokeStaticRecordType {\
  static let recordType = "SmokeStaticRecordType"\
}\
' \
  "$FIXTURE_ROOT/Foqos/CloudKit/SyncModels.swift" >"$TEST_ROOT/SyncModels.swift"
cp "$TEST_ROOT/SyncModels.swift" "$FIXTURE_ROOT/Foqos/CloudKit/SyncModels.swift"
assert_drift \
  'MISSING from manifest: RECORD TYPE SmokeStaticRecordType' \
  'static recordType discovery must report a fake type'

# Literal CKRecord record-type discovery.
reset_fixture
sed '/let rootRecord = CKRecord(recordType: "FamilyRoot"/i\
      _ = CKRecord(recordType: "SmokeLiteralRecord", recordID: rootRecordID)
' \
  "$FIXTURE_ROOT/Foqos/CloudKit/CloudKitNetworkService+Sharing.swift" \
  >"$TEST_ROOT/CloudKitNetworkService+Sharing.swift"
cp \
  "$TEST_ROOT/CloudKitNetworkService+Sharing.swift" \
  "$FIXTURE_ROOT/Foqos/CloudKit/CloudKitNetworkService+Sharing.swift"
assert_drift \
  'MISSING from manifest: RECORD TYPE SmokeLiteralRecord' \
  'literal CKRecord discovery must report a fake type'

# RecordKey enum discovery.
reset_fixture
sed '/static let createdBy = "createdBy"/a\
    static let smokeRecordKey = "smokeRecordKey"
' \
  "$FIXTURE_ROOT/Foqos/Models/FamilyCommand.swift" >"$TEST_ROOT/FamilyCommand.swift"
cp "$TEST_ROOT/FamilyCommand.swift" "$FIXTURE_ROOT/Foqos/Models/FamilyCommand.swift"
assert_drift \
  'MISSING from manifest: RECORD TYPE FamilyCommand.smokeRecordKey' \
  'RecordKey discovery must report a fake field'

# FamilyRoot subscript-write discovery.
reset_fixture
sed '/rootRecord\["createdAt"\] = Date()/a\
      rootRecord["smokeFamilyRootField"] = Date()
' \
  "$FIXTURE_ROOT/Foqos/CloudKit/CloudKitNetworkService+Sharing.swift" \
  >"$TEST_ROOT/CloudKitNetworkService+Sharing.swift"
cp \
  "$TEST_ROOT/CloudKitNetworkService+Sharing.swift" \
  "$FIXTURE_ROOT/Foqos/CloudKit/CloudKitNetworkService+Sharing.swift"
assert_drift \
  'MISSING from manifest: RECORD TYPE FamilyRoot.smokeFamilyRootField' \
  'FamilyRoot write discovery must report a fake field'

# A code-live manifest type cannot use a type-only entry to hide schema fields.
reset_fixture
sed '/let rootRecord = CKRecord(recordType: "FamilyRoot"/i\
      _ = CKRecord(recordType: "SmokeFieldless", recordID: rootRecordID)
' \
  "$FIXTURE_ROOT/Foqos/CloudKit/CloudKitNetworkService+Sharing.swift" \
  >"$TEST_ROOT/CloudKitNetworkService+Sharing.swift"
cp \
  "$TEST_ROOT/CloudKitNetworkService+Sharing.swift" \
  "$FIXTURE_ROOT/Foqos/CloudKit/CloudKitNetworkService+Sharing.swift"
sed '$a\
RECORD TYPE SmokeFieldless
' \
  "$FIXTURE_ROOT/fastlane/required-prod-schema.txt" >"$TEST_ROOT/required-prod-schema.txt"
cp "$TEST_ROOT/required-prod-schema.txt" "$FIXTURE_ROOT/fastlane/required-prod-schema.txt"
sed '$a\
\
    RECORD TYPE SmokeFieldless (\
        ghostField STRING\
    );
' \
  "$FIXTURE_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb" >"$TEST_ROOT/cloudkit-schema.ckdb"
cp "$TEST_ROOT/cloudkit-schema.ckdb" "$FIXTURE_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb"
assert_drift \
  'FIELDLESS live manifest type: RECORD TYPE SmokeFieldless' \
  'a fieldless live manifest type must fail closed'

echo "PASS: CloudKit schema drift discovery and fieldless-manifest guards"
