#!/bin/bash
# Release gate: verify every record type this build requires exists in the
# DEPLOYED CloudKit PRODUCTION schema. Fails closed: any cktool error aborts.
# This checks record-type existence only; it does not compare field definitions.
set -euo pipefail

# Keep this list in sync whenever the script starts invoking another external tool.
required_commands=(dirname grep xcrun)
for required_command in "${required_commands[@]}"; do
  command -v "$required_command" >/dev/null || {
    echo "Required command not found: $required_command" >&2
    exit 127
  }
done

if ! xcrun --find cktool >/dev/null 2>&1; then
  echo "Required Xcode tool not found: cktool" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIRED_FILE="$REPO_ROOT/fastlane/required-prod-schema.txt"
TEAM_ID="BU7526J4QY"
CONTAINER_ID="iCloud.com.cynexia.family-foqos"

if [[ ! -r "$REQUIRED_FILE" ]]; then
  echo "Required schema file is empty or unreadable: $REQUIRED_FILE" >&2
  exit 2
fi

checked=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  checked=$((checked + 1))
done <"$REQUIRED_FILE"

if [[ "$checked" -eq 0 ]]; then
  echo "Required schema file is empty or unreadable: $REQUIRED_FILE" >&2
  exit 2
fi

SCHEMA=$(xcrun cktool export-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment production)

missing=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  if ! grep -qF "$line (" <<<"$SCHEMA"; then
    echo "MISSING in production schema: $line"
    missing=1
  fi
done <"$REQUIRED_FILE"

if [[ "$missing" -eq 1 ]]; then
  echo "Production schema is behind this build. Deploy via CloudKit Console (#346), then re-run."
  exit 1
fi
echo "Production schema OK."
