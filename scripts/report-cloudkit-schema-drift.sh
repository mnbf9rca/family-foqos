#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

required_commands=(awk comm dirname mktemp rg rm sort)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "Required command not found: $required_command" >&2
    exit 127
  }
done

REPO_ROOT="${CLOUDKIT_SCHEMA_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MANIFEST_FILE="$REPO_ROOT/fastlane/required-prod-schema.txt"
SCHEMA_FILE="$REPO_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb"
TYPE_ROOTS=(Foqos FoqosDeviceMonitor FoqosShieldConfig FoqosWidget)
FIELD_KEY_FILES=(Foqos/CloudKit/SyncModels.swift Foqos/CloudKit/ProfileSessionRecord.swift)
RECORD_KEY_FILES=(
  Foqos/Models/DeviceHeartbeat.swift
  Foqos/Models/FamilyCommand.swift
  Foqos/Models/FamilyLockCode.swift
  Foqos/Models/FamilyMember.swift
)
FAMILY_ROOT_FILES=(
  Foqos/CloudKit/CloudKitNetworkService.swift
  Foqos/CloudKit/CloudKitNetworkService+Sharing.swift
)

for relative_path in "${TYPE_ROOTS[@]}" "${FIELD_KEY_FILES[@]}" \
  "${RECORD_KEY_FILES[@]}" "${FAMILY_ROOT_FILES[@]}"; do
  [[ -r "$REPO_ROOT/$relative_path" ]] || {
    echo "Required CloudKit source is unreadable: $REPO_ROOT/$relative_path" >&2
    exit 2
  }
done
for input_file in "$MANIFEST_FILE" "$SCHEMA_FILE"; do
  [[ -r "$input_file" && -s "$input_file" ]] || {
    echo "Required CloudKit schema input is empty or unreadable: $input_file" >&2
    exit 2
  }
done

TEMP_DIR=$(mktemp -d)
cleanup() { rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT

TYPE_PATHS=()
for relative_path in "${TYPE_ROOTS[@]}"; do TYPE_PATHS+=("$REPO_ROOT/$relative_path"); done
FIELD_PATHS=()
for relative_path in "${FIELD_KEY_FILES[@]}"; do FIELD_PATHS+=("$REPO_ROOT/$relative_path"); done
RECORD_PATHS=()
for relative_path in "${RECORD_KEY_FILES[@]}"; do RECORD_PATHS+=("$REPO_ROOT/$relative_path"); done
ROOT_PATHS=()
for relative_path in "${FAMILY_ROOT_FILES[@]}"; do ROOT_PATHS+=("$REPO_ROOT/$relative_path"); done

CODE_RAW="$TEMP_DIR/code.raw"
: >"$CODE_RAW"

rg --no-filename -o 'static let recordType\s*=\s*"[^"]+"' "${TYPE_PATHS[@]}" |
  awk '{ value=$0; sub(/^static let recordType[[:space:]]*=[[:space:]]*"/, "", value); sub(/".*$/, "", value); print "RECORD TYPE " value }' \
  >>"$CODE_RAW"

rg --no-filename -o 'CKRecord\(recordType:\s*"[^"]+"' "${TYPE_PATHS[@]}" |
  awk '{ value=$0; sub(/^.*recordType:[[:space:]]*"/, "", value); sub(/".*$/, "", value); print "RECORD TYPE " value }' \
  >>"$CODE_RAW"

rg -n 'static let recordType|enum FieldKey: String|^[[:space:]]+case [[:alnum:]_]+( = "[^"]+")?$' \
  "${FIELD_PATHS[@]}" >/dev/null
awk '
  FNR == 1 { type=""; fields=0 }
  /static let recordType[[:space:]]*=[[:space:]]*"/ {
    type=$0; sub(/^.*static let recordType[[:space:]]*=[[:space:]]*"/, "", type); sub(/".*$/, "", type)
  }
  /enum FieldKey:[[:space:]]*String/ { fields=1; next }
  fields && /^[[:space:]]*}/ { fields=0; next }
  fields && /^[[:space:]]+case / {
    field=$0; sub(/^[[:space:]]*case[[:space:]]+/, "", field)
    if (field ~ /=/) { sub(/^.*=[[:space:]]*"/, "", field); sub(/".*$/, "", field) }
    else sub(/[[:space:]].*$/, "", field)
    if (type != "") print "RECORD TYPE " type "." field
  }
' "${FIELD_PATHS[@]}" >>"$CODE_RAW"

rg -n 'static let recordType|enum RecordKey|^[[:space:]]+static let [[:alnum:]_]+ = "[^"]+"' \
  "${RECORD_PATHS[@]}" >/dev/null
awk '
  FNR == 1 { type=""; keys=0 }
  /static let recordType[[:space:]]*=[[:space:]]*"/ {
    type=$0; sub(/^.*static let recordType[[:space:]]*=[[:space:]]*"/, "", type); sub(/".*$/, "", type)
  }
  /enum RecordKey/ { keys=1; next }
  keys && /^[[:space:]]*}/ { keys=0; next }
  keys && /^[[:space:]]+static let / {
    field=$0; sub(/^.*=[[:space:]]*"/, "", field); sub(/".*$/, "", field)
    if (type != "") print "RECORD TYPE " type "." field
  }
' "${RECORD_PATHS[@]}" >>"$CODE_RAW"

rg --no-filename -o 'rootRecord\["[^"]+"\]' "${ROOT_PATHS[@]}" |
  awk '{ field=$0; sub(/^.*\["/, "", field); sub(/"\].*$/, "", field); print "RECORD TYPE FamilyRoot." field }' \
  >>"$CODE_RAW"

sort -u "$CODE_RAW" >"$TEMP_DIR/code"
awk '/^RECORD TYPE / { print }' "$MANIFEST_FILE" | sort -u >"$TEMP_DIR/manifest"
awk '
  /^[[:space:]]*RECORD TYPE / {
    type=$0; sub(/^[[:space:]]*RECORD TYPE /, "", type); sub(/[[:space:]]*\(.*/, "", type)
    print "RECORD TYPE " type; in_record=1; next
  }
  in_record && /^[[:space:]]*\);/ { in_record=0; next }
  in_record {
    line=$0; sub(/^[[:space:]]*/, "", line)
    if (line == "" || line ~ /^\/\// || line ~ /^GRANT / || line ~ /^"___/) next
    field=line; sub(/[[:space:]].*$/, "", field)
    print "RECORD TYPE " type "." field
  }
' "$SCHEMA_FILE" | sort -u >"$TEMP_DIR/schema"

# Built-in CloudKit sharing record intentionally exists in manifest/schema but not app declarations.
MANIFEST_ONLY_EXCEPTION='RECORD TYPE "cloudkit.share"'
# Deprecated FamilyPolicy intentionally remains in the additive-only checked-in schema.
SCHEMA_ONLY_EXCEPTION_PREFIX='RECORD TYPE FamilyPolicy'

comm -23 "$TEMP_DIR/code" "$TEMP_DIR/manifest" >"$TEMP_DIR/missing-manifest"
comm -13 "$TEMP_DIR/code" "$TEMP_DIR/manifest" |
  awk -v exception="$MANIFEST_ONLY_EXCEPTION" '$0 != exception' >"$TEMP_DIR/extra-manifest"
comm -23 "$TEMP_DIR/manifest" "$TEMP_DIR/schema" >"$TEMP_DIR/missing-schema"
comm -13 "$TEMP_DIR/manifest" "$TEMP_DIR/schema" |
  awk -v prefix="$SCHEMA_ONLY_EXCEPTION_PREFIX" '
    NR == FNR {
      if ($0 ~ /^RECORD TYPE "/) {
        rest=substr($0, length("RECORD TYPE ") + 1)
        quote=index(substr(rest, 2), "\"") + 1
        type="RECORD TYPE " substr(rest, 1, quote)
        if (length(rest) > quote) has_fields[type]=1
      } else {
        rest=substr($0, length("RECORD TYPE ") + 1)
        dot=index(rest, ".")
        type=dot ? "RECORD TYPE " substr(rest, 1, dot - 1) : $0
        if (dot) has_fields[type]=1
      }
      manifest_types[type]=1
      next
    }
    index($0, prefix) == 1 { next }
    {
      if ($0 ~ /^RECORD TYPE "/) {
        rest=substr($0, length("RECORD TYPE ") + 1)
        quote=index(substr(rest, 2), "\"") + 1
        type="RECORD TYPE " substr(rest, 1, quote)
      } else {
        rest=substr($0, length("RECORD TYPE ") + 1)
        dot=index(rest, ".")
        type=dot ? "RECORD TYPE " substr(rest, 1, dot - 1) : $0
      }
      if ($0 != type && manifest_types[type] && !has_fields[type]) next
      print
    }
  ' "$TEMP_DIR/manifest" - >"$TEMP_DIR/extra-schema"

drift=0
while IFS= read -r line; do [[ -z "$line" ]] || { echo "MISSING from manifest: $line"; drift=1; }; done <"$TEMP_DIR/missing-manifest"
while IFS= read -r line; do [[ -z "$line" ]] || { echo "EXTRA in manifest: $line"; drift=1; }; done <"$TEMP_DIR/extra-manifest"
while IFS= read -r line; do [[ -z "$line" ]] || { echo "MISSING from checked-in schema: $line"; drift=1; }; done <"$TEMP_DIR/missing-schema"
while IFS= read -r line; do [[ -z "$line" ]] || { echo "EXTRA in checked-in schema: $line"; drift=1; }; done <"$TEMP_DIR/extra-schema"

if [[ "$drift" -ne 0 ]]; then
  echo "CloudKit schema drift detected."
  exit 1
fi
echo "OK: no CloudKit schema drift."
