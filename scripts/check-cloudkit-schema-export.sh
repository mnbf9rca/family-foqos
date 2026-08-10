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
  if ! grep -qF "$requirement (" "$SCHEMA_FILE"; then
    echo "MISSING from checked-in CloudKit schema: $requirement"
    missing=1
  fi
done <"$REQUIRED_FILE"

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "Checked-in CloudKit schema covers every required record type."
