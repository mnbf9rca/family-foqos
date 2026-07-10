# #267 CKSyncEngine — manual two-device acceptance checklist

Run on two devices signed into the SAME iCloud account with Profile Sync enabled.
Required rows should be practical to execute during PR verification. Optional stress rows
cover edge cases that are either hard to force reliably or recoverable by the user running
Reset Sync again.

## Required Manual Acceptance

- [ ] **Reset Sync — Keep App Selections:** origin re-seeds; other device keeps its
      blocked-app selections; profiles/locations/emergency settings converge (§8.5, §8.1).
- [ ] **Reset Sync — Clear App Selections:** other device's profiles show
      `needsAppSelection`; must re-select apps; origin keeps its own selections (§8.5 E-2).
- [ ] **Concurrent edit:** edit the same profile on both devices; both converge, the
      loser surfaces a conflict banner, no data lost (branch E, I8).
- [ ] **Device offline across a reset:** offline device rejoins → applies the current
      command once (§8.3), re-seeds its local data (I11); nothing deleted (N1).
- [ ] **Toggle off → local delete → on:** delete propagates on re-enable via the surviving
      tombstone (I12/N5).
- [ ] **Toggle off → remote delete → on:** the remotely-deleted record resurrects from the
      rejoin seed (N5, deliberate keep-bias).

## Optional Stress Cases

These rows are useful when time and device state make them practical, but they are not
required PR blockers. If one fails in real use, the supported user recovery is to run
Reset Sync and let the current device become the new seed.

- [ ] **Delete-vs-edit race, order A:** delete on A while editing on B → B's edit either
      recreates (branch U-save) or the delete wins; converges, keep-biased (N12).
- [ ] **Delete-vs-edit race, order B:** edit on A while deleting on B → same, no husk
      survives once both fetch (I12 tombstone + pending-delete-wins, S-32).
- [ ] **Token-expired device across a reset:** device past change-token lifetime rejoins
      → re-seeds; note N10 residual (foreign deletions not re-expressible). This is hard
      to force on demand; record "not executed" unless a naturally expired device is available.
- [ ] **Active session across a reset (stop-on-absent, order A):** exercise the stale-owner
      stop path after the session record was removed by reset.
      1. On device A, start a session for a synced profile and wait until device B mirrors
         that active session.
      2. On device B, run Settings > Reset Syncing > Keep App Selections. Wait for both
         devices to finish syncing after the reset/re-seed.
      3. On device A, stop the still-active session. Bring device B to the foreground or tap
         Sync Now if it does not update immediately.
      4. Pass: device B stops the mirrored session; neither device loses profile/location/
         emergency data; no duplicate active session remains. If logs are collected, note
         whether the stop wrote a fresh stopped record because the server record was absent
         (§6 create-if-absent, S-24).
- [ ] **Active session across a reset (stop-on-absent, order B):** exercise the race where a
      post-reset fresh start beats the stale-owner stop.
      1. On device A, start a session for a synced profile and wait until device B mirrors
         that active session.
      2. On device B, run Settings > Reset Syncing > Keep App Selections. Wait for the
         reset/re-seed to complete and for device B to be able to start a fresh session for
         that profile.
      3. On device B, start a new session for the same profile. Before device A has observed
         that fresh start, stop the original pre-reset session on device A.
      4. Pass: device B's newer active session remains active; device A's stale stop does
         not overwrite it. If logs are collected, record whether the stale stop yielded to
         `serverRecordChanged` (S-24). If the UI never permits the fresh start without
         already observing/stopping the old session, record "not forced manually" and rely
         on `SessionStopOnAbsentTests.testGivenConcurrentFreshStartWins_WhenStopOnAbsent_ThenStopYieldsAlreadyStopped`.
- [ ] **Purge (delete DeviceSync zone in Settings > iCloud):** exercise the user-initiated
      CloudKit purge path, not Reset Sync.
      1. Confirm both devices have Profile Sync enabled and show the same synced profile data.
      2. In the iOS Settings app, open the Apple Account/iCloud storage controls and delete
         Family Foqos' iCloud data. The exact label varies by iOS build; use the control that
         deletes the app's iCloud data from iCloud, not the app uninstall/offload controls.
      3. Launch Family Foqos on both devices.
      4. Pass before re-enable: local profiles, locations, emergency settings, and app
         selections remain on each device; Profile Sync disables; the purge notice appears
         once and does not repeat on the next launch.
      5. Re-enable Profile Sync explicitly on one device. Pass after re-enable: this is
         treated as fresh consent, the device seeds its current local data, and normal sync
         resumes (T6, S-4).

## Not Routine Manual Acceptance

These are design residuals/edge cases rather than normal PR verification rows. They are
covered by automated tests where practical, and user-facing recovery is Reset Sync.

- **Account switch and back:** switching iCloud accounts on physical devices is too
  disruptive for routine acceptance. Expected behavior remains: neither namespace is
  purged; the original account resumes when switched back (T7/§7, S-12).
- **Restore-from-backup then edit:** restoring a device backup is too expensive for
  routine acceptance. Expected behavior remains: restored device heals forward;
  own-origin newer version applies (S-31).
