#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIRED_FILE="$REPO_ROOT/fastlane/required-prod-schema.txt"
SCHEMA_FILE="$REPO_ROOT/Foqos/CloudKit/cloudkit-schema.ckdb"

if [[ ! -r "$REQUIRED_FILE" || ! -s "$REQUIRED_FILE" ]]; then
  echo "Required schema file is empty or unreadable: $REQUIRED_FILE" >&2
  exit 2
fi
if [[ ! -r "$SCHEMA_FILE" || ! -s "$SCHEMA_FILE" ]]; then
  echo "Checked-in CloudKit schema is empty or unreadable: $SCHEMA_FILE" >&2
  exit 2
fi

SCHEMA_REQUIREMENTS=$(mktemp)
cleanup() {
  rm -f -- "$SCHEMA_REQUIREMENTS"
}
trap cleanup EXIT

awk '
  /^[[:space:]]*RECORD TYPE[[:space:]]+/ {
    record_type = $0
    sub(/^[[:space:]]*RECORD TYPE[[:space:]]+/, "", record_type)
    sub(/[[:space:]]*\(.*/, "", record_type)
    print "RECORD TYPE " record_type
    in_record = 1
    next
  }
  in_record && /^[[:space:]]*\);/ {
    in_record = 0
    next
  }
  in_record {
    field = $0
    sub(/^[[:space:]]*/, "", field)
    if (field == "" || field ~ /^\/\// || field ~ /^GRANT[[:space:]]/) {
      next
    }
    split(field, parts, /[[:space:]]+/)
    print "RECORD TYPE " record_type "." parts[1]
  }
' "$SCHEMA_FILE" >"$SCHEMA_REQUIREMENTS"

checked=0
while IFS= read -r requirement; do
  [[ -z "$requirement" || "$requirement" == \#* ]] && continue
  checked=$((checked + 1))
done <"$REQUIRED_FILE"

if [[ "$checked" -eq 0 ]]; then
  echo "Required schema file is empty or unreadable: $REQUIRED_FILE" >&2
  exit 2
fi

missing=0
while IFS= read -r requirement; do
  [[ -z "$requirement" || "$requirement" == \#* ]] && continue
  if ! grep -qFx "$requirement" "$SCHEMA_REQUIREMENTS"; then
    echo "MISSING from checked-in CloudKit schema: $requirement"
    missing=1
  fi
done <"$REQUIRED_FILE"

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "Checked-in CloudKit schema covers every required record type and field."
echo "Next: if preparing a release, promote via docs/cloudkit-production-schema.md"
