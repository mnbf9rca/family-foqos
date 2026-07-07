#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

# (1) T-C2-U21 - AppBlockerUtil must stay lock-free (G15).
if grep -nE 'withLock|SharedData\.(get|set|end|start|clear|flush|create)' \
  Packages/FoqosShared/Sources/FoqosShared/AppBlockerUtil.swift; then
  echo "❌ AppBlockerUtil must not lock or read SharedData (G15/T-C2-U21)"
  fail=1
fi

# (2) T-C2-U28 - the monitor extension must never mutate DeviceActivity registrations (I5).
if grep -rnE '\.(startMonitoring|stopMonitoring)\(' FoqosDeviceMonitor/; then
  echo "❌ Extension must not call start/stopMonitoring (I5/T-C2-U28)"
  fail=1
fi

# The extension-reachable backstop/legacy handlers likewise never register.
for f in Packages/FoqosShared/Sources/FoqosShared/Timers/BreakDeadlineBackstopActivity.swift \
  Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteDeadlineBackstopActivity.swift \
  Packages/FoqosShared/Sources/FoqosShared/Timers/BreakTimerActivity.swift \
  Packages/FoqosShared/Sources/FoqosShared/Timers/OneMoreMinuteTimerActivity.swift; do
  if grep -nE '\.(startMonitoring|stopMonitoring)\(' "$f"; then
    echo "❌ $f (extension-reachable) must not register (I5)"
    fail=1
  fi
done

# (3) Guard-parity - no public withLock-wrapped SharedData accessor inside a C2 grant section.
# RestrictionGrants.swift bodies run inside withLockStatus; they must use rawActiveSession /
# rawCommitActiveSession, never getActiveSharedSession()/set*/end*/create*.
if grep -nE 'SharedData\.(getActiveSharedSession|setBreak|setOneMoreMinute|clearOneMoreMinute|setEndTime|endActiveSharedSession|createActiveSharedSession|flushActiveSession)\(' \
  Packages/FoqosShared/Sources/FoqosShared/RestrictionGrants.swift; then
  echo "❌ RestrictionGrants sections must use raw* seams, not public withLock accessors (D-C2-4(ii))"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✅ C2 guards passed"
fi
exit "$fail"
