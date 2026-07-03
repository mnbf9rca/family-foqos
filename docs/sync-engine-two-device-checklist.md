# #267 CKSyncEngine — manual two-device acceptance checklist

Run on two devices signed into the SAME iCloud account with Profile Sync enabled,
unless a row says otherwise. Each row lists the action and the expected result.

- [ ] **Reset Sync — Keep App Selections:** origin re-seeds; other device keeps its
      blocked-app selections; profiles/locations/emergency settings converge (§8.5, §8.1).
- [ ] **Reset Sync — Clear App Selections:** other device's profiles show
      `needsAppSelection`; must re-select apps; origin keeps its own selections (§8.5 E-2).
- [ ] **Concurrent edit:** edit the same profile on both devices; both converge, the
      loser surfaces a conflict banner, no data lost (branch E, I8).
- [ ] **Delete-vs-edit race, order A:** delete on A while editing on B → B's edit either
      recreates (branch U-save) or the delete wins; converges, keep-biased (N12).
- [ ] **Delete-vs-edit race, order B:** edit on A while deleting on B → same, no husk
      survives once both fetch (I12 tombstone + pending-delete-wins, S-32).
- [ ] **Device offline across a reset:** offline device rejoins → applies the current
      command once (§8.3), re-seeds its local data (I11); nothing deleted (N1).
- [ ] **Token-expired device across a reset:** device past change-token lifetime rejoins
      → re-seeds; note N10 residual (foreign deletions not re-expressible).
- [ ] **Active session across a reset (stop-on-absent, order A):** stop on the owner →
      mirror stops via §6 create-if-absent stopped record (S-24).
- [ ] **Active session across a reset (stop-on-absent, order B):** concurrent fresh start
      wins the race → the stop yields (`serverRecordChanged`, S-24).
- [ ] **Purge (delete DeviceSync zone in Settings > iCloud):** data intact locally; sync
      disables; one-time notice; re-enable is fresh consent (T6, S-4).
- [ ] **Account switch and back:** switch iCloud account, then back → neither namespace
      purged; A resumes (T7/§7, S-12).
- [ ] **Toggle off → local delete → on:** delete propagates on re-enable via the surviving
      tombstone (I12/N5).
- [ ] **Toggle off → remote delete → on:** the remotely-deleted record resurrects from the
      rejoin seed (N5, deliberate keep-bias).
- [ ] **Restore-from-backup then edit:** restored device heals forward; own-origin newer
      version applies (S-31).
