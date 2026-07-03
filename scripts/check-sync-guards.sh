#!/usr/bin/env bash
# I5: no CKQuery in the private-DB sync path. I2: state.add(.saveRecord/.deleteRecord)
# for data records only in the whitelisted files. Run from repo root.
set -euo pipefail

status=0

# --- I5: no CKQuery / predicate fetch in the private-DB sync path -------------
# CloudKitManager/CloudKitNetworkService are the shared-DB family-sharing channel
# (out of scope, B2) and may legitimately query. SessionSyncService uses CAS
# record fetches, not CKQuery, and is allowed.
i5_files=$(git ls-files 'Foqos/CloudKit/*.swift' 'Foqos/CloudKit/SyncEngine/*.swift' \
  | grep -vE 'CloudKitManager|CloudKitNetworkService')
if echo "$i5_files" | xargs grep -nE 'CKQuery|CKQueryOperation|records\(matching:|NSPredicate' ; then
  echo "❌ I5 VIOLATION: CKQuery remains in the private-DB sync path (see above)."
  status=1
else
  echo "✅ I5: no CKQuery in the private-DB sync path."   # assertNoCKQueryInSyncPath
fi

# --- I2: outbound data-record enqueues only in whitelisted sites -------------
whitelist='MutationFunnel|SyncEngineController|SyncApplyService|LegacyCleanupCoordinator|SyncEngineController\+|SyncEngineDriver'
hits=$(git ls-files 'Foqos/**/*.swift' 'Foqos/*.swift' \
  | xargs grep -nE 'add\(pendingRecordZoneChanges' 2>/dev/null \
  | grep -vE "$whitelist" || true)
if [ -n "$hits" ]; then
  echo "❌ I2 VIOLATION: state.add outside the whitelist:"
  echo "$hits"
  status=1
else
  echo "✅ I2: outbound record enqueues only in whitelisted sites."  # assertStateAddWhitelisted
fi

exit $status
