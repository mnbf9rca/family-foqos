#!/bin/bash
# Release gate: verify every record type this build requires exists in the
# DEPLOYED CloudKit PRODUCTION schema. Fails closed: any cktool error aborts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIRED_FILE="$REPO_ROOT/fastlane/required-prod-schema.txt"
TEAM_ID="BU7526J4QY"
CONTAINER_ID="iCloud.com.cynexia.family-foqos"

SCHEMA=$(xcrun cktool export-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment production)

missing=0
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  if ! grep -qF "$line" <<<"$SCHEMA"; then
    echo "MISSING in production schema: $line"
    missing=1
  fi
done <"$REQUIRED_FILE"

if [[ "$missing" -eq 1 ]]; then
  echo "Production schema is behind this build. Deploy via CloudKit Console (#346), then re-run."
  exit 1
fi
echo "Production schema OK."
