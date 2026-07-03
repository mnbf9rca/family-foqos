# A1 adversarial verification — round 2 findings (verbatim)

- **Target design:** rev 3 (read-verified clearable holds + date watermark)
- **Context:** acceptance corpus for #267; see `2026-07-02-reset-sync-a1-acceptance-corpus.md`.
- **Provenance:** machine-extracted, unedited output of the independent verifier agents.

## Lens: readVerification — verdict: has-holes

**Verifier reasoning:**

> Rev 3's core invariant is much stronger than rev 2 — I confirmed it defeats all seven rev-2 breaks it was built against: holds-on-sight + same-pass superset verification correctly neutralizes push-ack races, non-read-your-writes follow-up pulls, stale push tasks, mutual marker deletion (wipes exclude markers), >400 wedges (chunking), origin-clock TTL anchoring (server creationDate), and 7-14d-fast receiver clocks (.skipExpired grace band + sight-based holds). Rows 15 and 16 and the intentional-behaviour-changes section are honest as stated (their preconditions are genuinely required, modulo the pre-existing #219 index-lag class the design legitimately carves out). I also verified pull ordering: pullResetRequests failures abort performFullSync before pullProfiles, and the zoneNotFound/unknownItem early-returns are matched by identical early-returns in pullProfiles/pullLocations, so no reconciliation runs without a marker fetch attempt; no other caller reaches the reconciliation handlers. However, the design has one real safety hole and one real liveness hole. Safety: the hold is a one-shot clearable flag while the danger (in-flight wipe, marker lifetime) is a window; after any legitimate verification-clear (e.g., a pass that races ahead of the wipe against a genuinely-complete zone), re-protection depends entirely on re-sighting the marker via a CKQuery that may be stale-absent — one such stale query (the exact same staleness budget row 20 accepts) lets a device that DID sight the marker reconcile against the post-wipe zone and permanently delete its own-only profiles/locations. This falsifies the interplay claim ('...or ever saw one ... not a pass longer') and shows row 20's precondition ('marker never sighted') is not actually required, i.e., that acceptance is stated too narrowly. The stale-presence direction additionally lets verification itself pass on false evidence, and an origin-side variant falsifies row 5. Liveness: the B1 watermark cap (now+1h) directly contradicts B5's loop-prevention whenever effectiveDate > receiver-now+1h (receiver clock >1h slow — squarely inside the stated skew-up-to-days model, and realistic for a screen-time app whose users manipulate clocks): the marker re-classifies .process every pass, and since each processing chains rePush + performFullSync, the loop is self-sustaining for ~(skew−1h), re-clearing user app selections every cycle, including past the 7-day exception window. Both holes have targeted fixes that preserve the design's shape (a persisted 7-day verification window keyed to last marker sight instead of a clearable hold; processed-request identity alongside the watermark). Plus two spec-consistency nits (unsatisfiable test 4.3/row 19; decode-independence of hold-set) whose main risk is an implementer 'fixing' the spec the wrong way. Verdict: has-holes — the invariant needs the window/identity amendments before implementation, but the overall architecture (sight-based protection + same-pass read-verification + persistent markers + watermark) is the right shape and survives everything else I threw at it.

### readVerification-1 [breaks-safety] Hold-clear is edge-triggered but the danger window is level-triggered: one stale-absent marker query after a legitimate verification-clear deletes real data

**Violated:**

The safety property (deletion of local BlockedProfiles/SavedLocation during a reset, outside all stated exceptions) and the spec's interplay claim: 'A2 protects every device that can see the marker (or ever saw one), for exactly as long as the zone lacks data that device could restore — and not a pass longer.' After a legitimate clear, re-protection depends entirely on per-pass re-sighting through a query that can be stale-absent — the exact staleness budget (one marker-invisible + deletions-visible query) that row 20 accepts, but row 20's stated precondition 'marker never sighted by this device' is NOT actually required: a device that sighted the marker and had its hold correctly set loses data the same way. Row 20's acceptance is therefore stated dishonestly-by-incompleteness, and rows 5 and 19's outcome claims are false under this interleaving.

**Interleaving:**

Setup: devices A (origin) and B. Profile P was created on B, pushed (syncVersion>0, normal schema), and A has NOT synced since — P exists only on B and in the zone. STEP 1 (t1): A runs resetSync: saves marker M; A's wipe has not landed yet (chunked wipe over multiple ops takes time). STEP 2 (t2): B runs performFullSync pass 1: pullResetRequests sights M -> both holds set, M classified .process, watermark advanced, didReceiveSyncReset dispatched (spawns re-push + follow-up-sync task). pullProfiles returns the still-complete pre-wipe zone -> remoteIds ⊇ B's restorable ids -> read-verification legitimately PASSES -> hold CLEARED, reconcile is a no-op. STEP 3 (t3): A's wipe executes. Its per-type snapshot contains P's recordID (recordIDs are stable = profileId), so P is deleted — including the copy B just re-pushed. A then re-pushes A's local data, which does not include P. STEP 4 (t4): B's follow-up sync (or a later notification-triggered pass): pullResetRequests query is STALE-ABSENT for M (index lag hiding a minutes-old record — explicitly permitted) -> zero markers sighted -> hold stays nil (set-if-nil never fires). pullProfiles now shows the true post-wipe zone: remoteIds = A's re-pushed set, non-empty (A3 doesn't fire), P absent, hold nil, backstop irrelevant -> reconciliation deletes P locally via BlockedProfiles.deleteProfile. The end-of-pass pushLocalData runs AFTER reconciliation, fetches local profiles post-deletion, and no longer includes P. P (and its selection/sessions) is permanently lost — no device or zone copy exists. The same trace works verbatim for SavedLocation with the location hold. Two variants use the same skeleton: (a) pass-1 verification passes on STALE PRESENCE of records the wipe already deleted (the superset check trusts positive query evidence, which the design's own constraint says can lag deletions); (b) origin-side: a manual performFullSync interleaved at resetSync's awaits verify-clears the origin's own step-3 holds against its pre-wipe pull before the wipe lands, falsifying row 5's outcome, after which one stale-absent sighting of its own marker exposes the origin's not-yet-re-pushed data mid-re-push.

**Verifier's suggested fix (historical; superseded by #267):**

Make protection a persisted time window, not a clearable flag: persist lastSightedResetAt (per data type if desired), set/refreshed by resetSync and by every marker sighting; require read-verification (superset proof, same-pass pulled set) for EVERY deletion reconciliation while now < lastSightedResetAt + processTTL (7d, with the same fail-toward-keep clamps), regardless of whether the current pass's query returned any marker. Verification passing every pass in a healthy zone preserves the same-pass-resume liveness goal, but a stale-absent marker query can no longer strip protection because the window outlives any single query. Optionally harden variant (a) by proving presence via fetch-by-recordID (record store, not the query index) for the device's restorable ids.

### readVerification-2 [breaks-liveness] Watermark cap at now+1h reintroduces the infinite reprocessing loop B5 claims to prevent whenever the receiver clock is >1h slow

**Violated:**

Liveness requirement 'no infinite reprocessing loops' and B5's own claim: 'The synchronous watermark advance prevents the follow-up pass from re-processing (infinite reset loop)' — the B1 cap and the B5 loop-prevention are mutually contradictory whenever effectiveDate > now+1h, and the cap's stated rationale (processing future-dated markers via the requestedAt fallback) confirms future-dated markers are intended to be processed. Secondary safety-exception overrun: repeated selection-clearing continues beyond the 7-day-old-reset allowance of exception (b) in wall-clock terms.

**Interleaving:**

Setup: receiver B's clock is s > 1h slow relative to server time (model allows days; kids rolling clocks back is a realistic threat for a screen-time app). Origin A resets with clearRemoteAppSelections=true; marker M has server creationDate E, so effectiveDate = E. STEP 1: B syncs at receiver-time n0 = E − s. classify: not own, age = n0 − E < 0 (not expired), E > watermark -> .process. B5: watermark advance is capped at min(E, n0+1h) = n0+1h < E (cap engages because E > now+1h). didReceiveSyncReset dispatched -> handleSyncReset clears ALL app selections, then chains Task { rePushLocalSyncedData (every profile + location, one CK call each); performFullSync }. STEP 2: that chained performFullSync re-runs pullResetRequests: M still classifies .process (E > watermark = now+1h, still capped) -> selections cleared AGAIN, full re-push AGAIN, another chained performFullSync. STEP 3: the chain is self-sustaining (it does not go through handleRemoteNotification, so the 5-minute throttle never applies) and loops continuously until receiver-clock now+1h catches up to E — duration ≈ s − 1h (days of continuous full-sync + full-re-push cycles for day-scale skew), or until the marker expires/GCs at receiver-relative E+7d / E+14d. Every cycle re-sets needsAppSelection=true and wipes selectedActivity on every profile, so any apps the user re-selects between cycles are cleared again; with s > 0 this re-clearing also continues past the point where the reset is more than 7 wall-clock days old (exceeding exception (b)'s window).

**Verifier's suggested fix (historical; superseded by #267):**

Add idempotency by identity, not only by time: persist the processed request's requestId (e.g., SharedData.lastProcessedResetId, or the set of processed ids seen within gcTTL) alongside the watermark, and have classify return .skipAlreadyProcessed when requestId matches regardless of effectiveDate-vs-watermark. Keep the now+1h cap solely for cross-request delivery ordering. Also define classify's expected output for future effectiveDates explicitly in the test plan (it is currently listed as a test input with no specified outcome).

### readVerification-3 [nit] Test plan 4.3 and row 19 are internally inconsistent: same-pass deletion after a verification-clear is provably unsatisfiable

**Violated:**

Internal consistency of the spec (invariant I vs. test plan item 4.3 and row 19). Risk: a TDD implementer forced to make 4.3 green may redefine 'restorable' more narrowly than 'deletable' (e.g., only records this device originated), which would silently reopen the #195 hole the invariant closes.

**Interleaving:**

Derivation, not a runtime trace: a verification-clearing pass requires remoteIds ⊇ {local ids with syncVersion>0 ∧ !isNewerSchemaVersion}. Reconciliation's deletable set is {local ids with syncVersion>0 ∧ id ∉ remoteIds}, minus isNewerSchemaVersion (A4) and syncVersion==0. Any deletable candidate is therefore restorable, hence in remoteIds — contradiction. So in the pass that clears the hold, no locally-held record can ever be deleted; test bullet 4.3's expected outcome 'one non-held remote-only deletion ⇒ hold cleared, absent local DELETED (same-pass resume)' cannot occur, and row 19's 'normal propagation resumes in the same pass' is misleading (real remote-deletion propagation resumes at the earliest the next hold-free pass, and per the intentional-changes section is usually reversed first by this device's every-pass push resurrecting the deleted record).

**Verifier's suggested fix (historical; superseded by #267):**

Reword 4.3 to assert the no-op: 'non-empty remote, hold set, remote ⊇ restorable locals, one remote-only id with no local counterpart ⇒ hold cleared, nothing deleted, reconciliation branch executed'; reword row 19 to say deletion propagation resumes from the next pass (and is typically preceded by re-push resurrection), and state explicitly that restorable ⊇ deletable must hold by construction.

### readVerification-4 [nit] Hold-set-on-sight is underspecified for undecodable marker records

**Violated:**

A2's stated intent ('no ... state ... can leave a device unprotected while a marker it can see exists') — the wording 'whenever its query result contains any SyncResetRequest record' is right, but the design's own decode/classify pipeline makes the decoded interpretation the natural implementation, and the failure direction is the catastrophic one.

**Interleaving:**

A future app version (or a corrupted write) produces a SyncResetRequest record that SyncResetRequest(from:) fails to decode, or fetchAllRecords returns it as a .failure per-record result. Origin wipes the zone under that marker. Receiver B's pullResetRequests fetches the record, but if the implementation counts only DECODED markers when setting holds (the spec's 'regardless of classification' is post-decode language, and classification is defined over decoded requests), B sets no hold, sees a partial mid-re-push zone in pullProfiles (non-empty, A3 silent), and reconciles-deletes its not-yet-re-pushed data with no protection.

**Verifier's suggested fix (historical; superseded by #267):**

State explicitly (and pin with a test) that holds are set when the raw fetched result set for record type SyncResetRequest is non-empty — counting .failure results and decode-nil records — before any decoding or classification runs.

## Lens: crashChurn — verdict: has-holes

**Verifier reasoning:**

> Human Meatbag — rev 3 is a real improvement over rev 2 (marker-before-wipe kills the durable landmine; wipes never touching markers kills mutual annihilation; chunking kills the >400 wedge; sight-based holds close the rev-2 ack races it set out to close; rows 11, 14, 15 and the last-deletion/newer-schema behaviour changes are honestly stated). But it has holes in exactly the new machinery. (1) Read-verification is itself a query-freshness bet: stale PRESENCE of wiped records falsely clears the hold, and the re-latch on the next pass depends on the marker being query-visible — stale absence there (the very lag row 20 is built on) leaves a previously-sighted device unprotected while deletions ARE visible, wiping its own-only data. The same shape breaks the 14-day backstop (clear-then-trust-next-pass relies on the previous pass's push being query-visible, violating the spec's own 'no safety decision may rely on a write being query-visible' constraint) and row 5 on the origin. Rows 16 and 20's acceptances are therefore not honest — their stated preconditions (persistent push FAILURE; marker NEVER sighted) are not required. (2) The clearing rule is self-defeating: verification passing implies the deletion set is empty (remoteIds ⊇ restorable-locals is precisely the no-deletions condition, and everything else is exempt), and every pass re-sights the persisted marker and re-sets the hold, so 'propagation resumes in the same pass' is vacuous, test-plan 4.3 is unsatisfiable, and genuine deletions during the ~14-day marker window are not deferred but reverted family-wide by every-pass pushes. (3) The now+1h watermark cap defeats B4/B5 idempotency whenever effectiveDate > now+1h (receiver ≥1h slow, or the requestedAt fallback with a fast origin): the follow-up sync re-classifies the same marker .process forever until the clock catches up — an infinite reprocess loop that re-clears selections for hours or days. (4) A weaker spec omission: fail-closed pass-abort on pullResetRequests failure is load-bearing but unstated. Verification method: full read of the spec and the three pre-fix files; grep confirmed all reconciliation-reaching paths flow through performFullSync with pullResetRequests first (SettingsView.swift:176/394/407, FoqosApp.swift:352, setupSync), so the error-path analysis in finding 4 is exhaustive over current callers. I could not break: resetSync crash rows 1–4/7 (marker-first ordering plus A3 genuinely holds under SIGKILL at every step boundary), hold-set-before-watermark B5 kill ordering (rows 8–9 honest), concurrent double resets (row 6, markers survive), the 7–14d skipExpired grace band (row 14 honest), sync disable/re-enable within the marker window (re-sight re-protects), and A4. Fixes for (1)+(2) point the same direction: replace the clearable latch + vacuous verification with a persisted quiet-period keyed to last marker sight, and state the resulting 7–14-day deletion-propagation suspension honestly; fix (3) with requestId-based idempotency.

### crashChurn-1 [breaks-safety] Hold latch falsely cleared by stale-presence verification, then never re-latched by stale-absent marker query — a device that DID sight the marker still wipes its own-only data (rows 16/20 acceptances state preconditions that are not actually required; A2 interplay claim and row 5 refuted)

**Violated:**

Safety property: local BlockedProfiles/SavedLocation deletion and FamilyActivitySelection loss on a device with no genuine remote deletion in flight, outside the honest scope of accepted residuals — rows 16 and 20 state preconditions ('14 straight days of failed pushes', 'marker never sighted by this device') that these interleavings show are not required, so exception (c) does not cover them. Also falsifies the spec's A2 interplay claim, row 5, and the constraint that no new index-freshness dependencies be added.

**Interleaving:**

Variant 1a (stale-presence clear): (1) Origin A runs resetSync: marker saved, watermark advanced, holds set, zone wiped, A re-pushes A's profiles. (2) Device B (holds own-only profiles P*, syncVersion>0) runs performFullSync pass 1: pullResetRequests sights the marker → profile hold set. (3) pullProfiles' CKQuery returns STALE PRESENCE — index has not caught up to the wipe, so remoteProfileIds still contains all of B's restorable ids. Read-verification (remoteIds ⊇ restorable locals) PASSES → hold CLEARED, reconciliation vacuous, end-of-pass push re-pushes P* (acked). (4) Pass 2: pullResetRequests suffers STALE ABSENCE of the still-existing marker (explicitly allowed: 'CKQuery results may lag ANY write arbitrarily... stale absence for existing ones' — the same lag the spec itself relies on in row 20) → zero sightings → hold stays nil. (5) pullProfiles now reflects the wipe plus A's re-push but NOT B's pass-1 pushes (not read-your-writes): remoteIds non-empty (A's records), P* absent. No hold, no marker, remoteIds non-empty → reconciliation runs → B deletes P* locally via BlockedProfiles.deleteProfile: FamilyActivitySelection and session history destroyed; P* returns later only as needsAppSelection husks (or never, if the pass-1 pushes had failed). Row 20's acceptance requires 'marker never sighted by this device' — B sighted it; the precondition is not actually required, so the acceptance is not honest and this interleaving falls outside it. Variant 1b (backstop clear): device D's hold set at day 0, sync disabled, re-enabled day 15. Pass 1: marker already GC'd (day 14) → no sight; hold age >14d → backstop clears it and skips reconciliation; end-of-pass push of D's data is ACKED. Pass 2: marker gone (GC'd — re-sight impossible, unlike the normal churn case), pull shows stale absence of D's just-pushed records (the spec's own constraint: 'a write this device just made (even server-acked) may be missing from the next query') → no hold → reconcile → D's own-only profiles deleted. Row 16 claims this residual requires '14 straight days of FAILED pushes' — here every push succeeded; only index lag was needed. Variant 1c (row 5): a notification-triggered performFullSync on the origin issues its pullProfiles query before the wipe; the result (pre-wipe snapshot = stale presence) arrives after resetSync set the holds mid-wipe → verification passes against the pre-wipe snapshot → origin's hold cleared DURING its own wipe, contradicting row 5's 'Holds already set ⇒ no reconciliation'. All three variants refute the interplay claim 'A2 protects every device that can see the marker (or ever saw one), for exactly as long as the zone lacks data that device could restore — and not a pass longer': protection ends the moment one query lies, and read-verification is itself a new dependency on index freshness, which the constraints section forbids ('this design merely must not add new dependencies on index freshness').

**Verifier's suggested fix (historical; superseded by #267):**

Stop treating the hold as a clearable latch. Persist lastMarkerSightAt (updated on every sight, and set by resetSync) and suppress deletion reconciliation for the full gcTTL window after the last sight, independent of any per-pass query evidence; drop read-verification-as-clearing entirely (per the next finding it only ever authorizes vacuous reconciliation, so nothing real is lost). For the backstop/offline case: after the quiet period expires, the first reconciling pass must still require remoteIds ⊇ restorable-locals in THAT pass whenever the previous pass pushed records absent from its own pull — or more simply, require one additional pass between 'this pass pushed missing data' and 'reconciliation allowed'. Restate rows 5, 16, 20 and the A2 interplay claim honestly if any residual is retained.

### crashChurn-2 [breaks-liveness] Read-verification-passing passes have a provably empty deletion set: 'same-pass resume' is vacuous, deletion propagation is actually suspended for the whole ~14-day marker lifetime, genuine deletions in the window are actively REVERTED, and test-plan item 4 bullet 3 is unsatisfiable

**Violated:**

Liveness requirement 'deletion propagation resumes after read-verification, bounded by the 14-day backstop' — it never resumes via read-verification (only via the accidental row-20 stale-absence window, i.e. propagation during the window depends on the exact index-lag event the design elsewhere treats as its dangerous residual); plus internal spec consistency (row 19, intentional-change bullet 1, test plan 4.3 contradict A2's own definitions).

**Interleaving:**

Proof of vacuousness: reconciliation deletes a local profile iff syncVersion>0 ∧ ¬isNewerSchemaVersion ∧ id ∉ remoteIds. That is exactly the 'restorable' set; verification passing means remoteIds ⊇ restorable ids. Therefore in every pass where the hold is cleared by verification, the deletion set is empty by definition (A4 and the syncVersion==0 rule exempt everything else). Since every subsequent pass re-sights the still-persisted marker and re-sets the cleared hold ('set... whenever its query result contains ANY SyncResetRequest record — regardless of classification'), every pass during the marker's ≤14-day life is a hold pass, and the only reconciliations permitted are these vacuous ones. Reversion interleaving: (1) Reset day 0, marker persists to day 14. (2) Day 2: device C deletes profile P locally and via deleteProfileFromSync removes its CK record — a genuine deletion with the reset long converged. (3) Device B (holds P, syncVersion>0) syncs: sights marker → hold set; pullProfiles: P absent → verification FAILS (P is restorable and missing) → reconciliation skipped; end-of-pass pushLocalData pushes ALL local profiles including P → P re-created in the zone. (4) C's next pass: 'upserts always apply' → createLocalProfile resurrects P on C as a needsAppSelection husk. (5) This repeats every pass until the marker is GC'd at day 14 (and indefinitely if the family resets more often than every 14 days). Consequences: row 19's outcome ('one non-held remote-only deletion ⇒ hold cleared, absent local deleted... Normal propagation resumes in the same pass; no timer wait') is mathematically impossible — an absent restorable local makes verification fail, and non-restorable locals are never deleted; test-plan item 4 bullet 3 encodes this impossible case and cannot be made to pass by any implementation satisfying the rest of the spec; the intentional-change bullet 'Non-last deletions propagate normally' is false for 14 days after every reset; and the liveness claim 'post-reset deletion propagation resumes within one pass, not after a timer' is false — real resumption is at marker GC + hold lapse, and deletions attempted in the window are not deferred but undone.

**Verifier's suggested fix (historical; superseded by #267):**

Accept and state the true behavior: while any marker is within gcTTL of last sight, deletion reconciliation is suspended, deletions made in that window may be resurrected by other devices' every-pass pushes, and propagation resumes only after the quiet period — then delete the vacuous same-pass-resume machinery and the unsatisfiable test case. If 14-day suspension after every reset is unacceptable, shorten the suspension by keying it to processTTL (7d) rather than gcTTL, or gate the every-pass pushLocalData so it does not re-push records that were present in this pass's own pull baseline and then vanished (requires remembering the last verified pull set — a partial tombstone substitute), acknowledging that a real fix is the out-of-scope change-token/tombstone sync.

### crashChurn-3 [breaks-liveness] Watermark cap (now+1h) breaks processing idempotency under receiver-slow clock ≥1h: infinite reset-reprocessing loop with repeated selection clearing, falsifying B5's no-infinite-loop claim

**Violated:**

Liveness: 'no infinite reprocessing loops' and B4 'process the newest, once'; secondarily the repeated destruction of user-restored FamilyActivitySelections stretches exception (b) far beyond a one-shot clear that is 'part of' the reset.

**Interleaving:**

(1) Receiver R's clock is 24h slow (clock skew 'up to days' is in scope; the same trace works with an honest receiver and a future-skewed requestedAt on the creationDate-nil fallback path). Marker effectiveDate = server creationDate S; R's now = S − 24h. (2) classify: not own-origin, not expired (age negative < 7d), effectiveDate > watermark → .process. (3) B5: advance watermark = min(S, now + 1h) = S − 23h, which is STILL < S. (4) didReceiveSyncReset dispatched → handleSyncReset clears app selections (flag=true), spawns rePushLocalSyncedData + follow-up performFullSync. (5) Follow-up pass: pullResetRequests sights the same marker; classify: effectiveDate S > watermark S − 23h → .process AGAIN → watermark 're-advanced' to now+1h (no progress) → selections cleared again → another re-push + another follow-up performFullSync. (6) Self-sustaining loop of full CloudKit sync passes, selection wipes, and full re-pushes, continuing ~23 hours until R's clock passes S − 1h; any app selections the user restores during that window are destroyed on the next iteration, and the loop also runs on every remote-notification and manual sync. B5's claim 'the synchronous watermark advance prevents the follow-up pass from re-processing (infinite reset loop)' is false whenever effectiveDate > now + 1h — the cap, introduced to protect delivery, silently sacrifices the idempotency B4/B5 depend on, and the spec's classification rules give no other skip for this marker (the test plan lists 'future effectiveDate' as a case but never states its required outcome).

**Verifier's suggested fix (historical; superseded by #267):**

Make idempotency identity-based, not date-based: persist lastProcessedResetRequestId (or a small pruned set of processed requestIds) in SharedData and classify .skipAlreadyProcessed on id match regardless of watermark; keep the capped watermark solely for retiring older markers and delivery ordering. Alternatively, cap the classification comparison symmetrically (compare min(effectiveDate, now+1h) against the watermark) so the advanced watermark is always ≥ the processed marker's comparison date. Specify the required outcome of the 'future effectiveDate' test.

### crashChurn-4 [weakens] Sight-protection's fail-closed dependency on pullResetRequests aborting the pass is never stated as a requirement

**Violated:**

Invariant (I) — its enforcement depends on an unstated ordering/abort property; the spec's own 'code-inspection commitments' section (the designated home for such non-unit-testable requirements) omits it.

**Interleaving:**

All sight-based protection assumes pullResetRequests runs, surfaces markers, and — on failure — prevents pullProfiles/pullLocations from reconciling. Today this holds only incidentally: performFullSync's try-chain aborts the whole pass when pullResetRequests throws (ProfileSyncManager.swift:345), and the zoneNotFound/unknownItem swallow inside pullResetRequests (line 411) is benign only because a zoneNotFound would equally empty pullProfiles' own catch and unknownItem-with-markers-present is practically impossible. The spec's data-flow diagram shows the ordering but neither the design text nor the 'code-inspection commitments' list requires that a pullResetRequests failure abort the pass. Interleaving after a plausible future refactor (e.g. 'log and continue so profile sync is not blocked by a flaky marker query'): (1) origin resets, marker saved, zone wiped; (2) receiver's pullResetRequests throws (CK throttling) and is caught-and-continued → no sight, no hold; (3) pullProfiles returns the partially re-pushed zone → non-empty remoteIds, no hold → reconciliation deletes the receiver's not-yet-re-pushed profiles. Exactly the #195 wipe, restored by an error-handling change the spec does not forbid — and it would strip protection precisely during CloudKit flakiness, when mid-reset zones are most likely to be observed.

**Verifier's suggested fix (historical; superseded by #267):**

Add to the code-inspection commitments: 'any pullResetRequests failure (other than a provably-empty result) must abort the pass before any pull whose handler can reconcile deletions; the zoneNotFound/unknownItem swallow is acceptable only while pullProfiles/pullLocations swallow the same codes without delivering.' Ideally also add a regression test asserting handleSyncedProfiles is never invoked in a pass where marker fetching failed (injectable seam permitting).

## Lens: cloudkitOps — verdict: has-holes

**Verifier reasoning:**

> Human Meatbag — verdict: has-holes. Rev 3's core invariant (same-pass read-verified reconciliation) is a genuine improvement over rev 2 and survives most of the attacks that killed its predecessor: I could not break marker-before-wipe ordering, the never-wipe-markers rule (two concurrent resets now coexist, row 6 holds), chunked deletes (row 7 holds), A3's empty-pull skip, A4's newer-schema exemption, or B5's holds-before-watermark crash ordering (rows 8/9 verified against the code paths — end-of-pass pushLocalData really does cover the killed-mid-re-push case). pushSyncedProfile's fetch-then-save racing a wipe fails safe (save policy rejects, local data untouched). Rows 15/16/20's acceptances were checked for honesty rather than reported as new findings — and two of the three turned out to be stated with preconditions narrower than the truth (findings 3 and 6; finding 5 shows row 20's 'never sighted' is likewise not the real precondition), which per my brief is reportable.
> 
> The design breaks in one confirmed safety hole and two liveness holes. (1) The fatal one: holds are global per-device state, cleared by whichever pass verifies first, but performFullSync is not serialized (verified: four unguarded call paths, including the follow-up sync the design itself spawns inside handleSyncReset) and the spec mandates reading the hold 'fresh, never captured at pass start' — so a slow/stale pull from pass1 reconciles unverified after pass2 clears the hold, deleting everything the partial set lacks. Invariant (I) only gates passes that observe a hold; it says nothing about a pass whose hold was consumed by a sibling. This needs pass-scoped clearing or pass serialization before implementation. (2) The now+1h watermark cap fires on the server-assigned creationDate (which cannot be skew-poisoned and never needed capping), so any receiver >1h slow re-processes the same marker forever in the self-chaining follow-up loop — including re-clearing selections every iteration for days. (3) The GC margin is 7 days, not the 14 rows 14/15 claim — B3's own prose admits it — so the delivery guarantee's clock carve-out is off by half.
> 
> The weakens-level findings are spec-hardening and honesty items: hold-set must count recordIDs (not decoded records) or a per-record fetch failure on the marker silently disarms protection in the most dangerous pass; the Interplay 'ever saw one' latching claim is false under stale-presence verification; row 16's residual also occurs when the final push succeeds but isn't query-visible, aggravated by gcTTL equaling the backstop. The account-switch nit fails safe for data. Out of scope but noted: external zone deletion via iCloud settings destroys markers and the subscription and can still yield partial-reseed deletions with A3-only protection — pre-existing behavior, not introduced or claimed-fixed by this design.

### cloudkitOps-1 [breaks-safety] Concurrent-pass hold-clear race: one pass's read-verification clears the hold, a second in-flight pass then reconciles an older/staler partial pull with no hold and no verification

**Violated:**

Invariant (I): pass1 reconciles deletions in a pass whose own pull proved nothing — the hold was consumed by a different pass with a different pulled set. Rows 10/19 implicitly assume the verifying set and the reconciling set belong to the same pass; the fresh-read rule makes clears (not just sets) visible cross-pass. Safety property: local BlockedProfiles/SavedLocation deleted while a reset is in flight, outside all exceptions.

**Interleaving:**

Device B (non-origin) already processed reset marker M in an earlier pass: hold set, B's data re-pushed, zone now converging. (1) Pass1 starts on B (zone-change notification, >5min after last completed sync): pullResetRequests sights M (hold already set, .skipAlreadyProcessed), then issues its pullProfiles query Q1. Q1 is slow, or is served by a stale index replica, and reflects the mid-wipe/mid-re-push zone: {P1} only, missing P2..Pn which B holds with syncVersion>0. Pass1 suspends at the await. (2) Pass2 starts on B (any of: the reset follow-up performFullSync spawned at SyncCoordinator.swift:558, setupSync:172, or the manual button — performFullSync has no reentrancy guard and never checks isSyncing). Pass2's pullProfiles returns the fresh full set S ⊇ B's restorable ids. In pass2's handleSyncedProfiles the hold is set, read-verification passes, the HOLD IS CLEARED (spec: 'the only clearing rule'), and pass2 reconciles harmlessly with S. (3) Q1 finally resolves; pass1's handleSyncedProfiles runs with remoteIds={P1}: non-empty, and the hold — explicitly 'read fresh (from SharedData) inside the reconciliation branch, never captured at pass start' — is now NIL, so no superset check runs at all. Pass1 deletes every local profile with syncVersion>0 not in {P1}: P2..Pn destroyed, including B-only profiles whose zone copies were wiped and not yet visible — permanent loss of those profiles plus all selections/session history. The identical race exists for the location hold. Note the design manufactures the overlap itself: the outer pass that processes M continues into pullProfiles while handleSyncReset's task chain (re-push → performFullSync) runs pass2 at the outer pass's awaits.

**Verifier's suggested fix (historical; superseded by #267):**

Serialize performFullSync per device (guard on isSyncing / an async queue — drop or queue overlapping passes, including the handleSyncReset follow-up), AND/OR make hold-clearing pass-scoped: reconciliation may proceed only if (hold was nil when THIS pass's pull was issued) or (THIS pass's own pull passed the superset check). E.g., store the hold with a monotonically increasing pull-sequence number; a pass records its sequence at pull time and may not treat a hold as cleared unless it cleared it itself.

### cloudkitOps-2 [breaks-liveness] Watermark cap at now+1h with a receiver clock >1h slow turns the reset follow-up into a self-sustaining infinite reprocessing loop (with repeated selection-clearing)

**Violated:**

Liveness: 'no infinite reprocessing loops'; B4 'process the newest, once'; B5's explicit no-loop claim. Also erodes the spirit of safety exception (b): selection-clearing is repeated indefinitely, not applied once per device.

**Interleaving:**

Receiver B's clock is 90 minutes behind server time (auto-set-time off — well within the 'clock skew up to days' envelope). (1) Origin resets; marker M has effectiveDate = server creationDate ≈ T. (2) B syncs at real T+5m: sight → hold; classify: effectiveDate T > watermark, age < 7d → .process. Watermark advance is capped: min(T, B.now+1h) = T−30m < effectiveDate. (3) didReceiveSyncReset runs: clears ALL app selections (flag true), re-pushes everything, then runs the built-in follow-up performFullSync. (4) Follow-up pass: pullResetRequests sights M again; classify: effectiveDate T > watermark (T−30m) → .process AGAIN → clear selections again → full re-push again → another follow-up pass. The loop is direct performFullSync calls, so the 5-minute notification throttle never applies. It self-sustains for (skew − 1h) of wall time — days for multi-day skew — burning battery/network with continuous full syncs and full re-pushes, and re-clearing FamilyActivitySelection on every iteration so the user's re-selections are destroyed within minutes of being made, for days. B5's claim that 'the synchronous watermark advance prevents the follow-up pass from re-processing (infinite reset loop)' is false whenever the cap keeps the watermark below effectiveDate; the cap fires on the trustworthy server-assigned creationDate, not just the skew-poisonable requestedAt fallback it was designed for.

**Verifier's suggested fix (historical; superseded by #267):**

Apply the +1h cap only when effectiveDate came from the requestedAt fallback (server creationDate cannot be poisoned by any device clock, so advancing the watermark fully to it is safe), and additionally persist the last-processed requestId so classify returns .skipAlreadyProcessed for an identical requestId regardless of date comparisons.

### cloudkitOps-3 [breaks-liveness] GC skew margin is 7 days, not 14: a receiver clock >7d fast destroys live markers; rows 14/15 and the liveness carve-out state the wrong threshold

**Violated:**

Liveness property as stated: 'resets reach every device syncing within 7 days (absent >14d-fast receiver clocks)' — broken by an 8d-fast clock. Honesty of accepted residuals: row 15's claimed precondition (>14d-fast) is not actually required (>7d suffices), and row 14's 'B3 margin protects the family' is false over time for that band.

**Interleaving:**

Family: device C's clock is 8 days fast (F=8d, under the documented >14d threshold) and syncs hourly; device D syncs every ~6.5 days. (1) Origin resets at T; marker M, effectiveDate T. (2) C at T+1h: perceived age 8d → 7–14d band → .skipExpired; row 14 asserts 'not GC'd (B3 margin protects the family)'. (3) C keeps syncing; at real T+6d its perceived age reaches 14d → .expiredCollect → C deletes M at real age 6 days, inside the 7-day processTTL. (4) D syncs at T+6d12h: no marker exists → reset never delivered to D (selection-clearing missed), and D never sights it, so D gets no hold — if the zone is still partial (any device's re-push failing), D reconciles with only A3 protection, i.e., row 15's harm materializes at F=8d. Arithmetic: a device F days fast GCs at real age ≥ 14−F, so any F>7 destroys a marker inside its live window — which B3's own prose concedes ('must be >7 days fast before it can destroy a marker other devices still need'), directly contradicting row 14's protection claim for the 7–14d band and row 15's '>14 days fast' precondition.

**Verifier's suggested fix (historical; superseded by #267):**

Either raise gcTTL to processTTL + the skew margin actually claimed (21d for a true 14d margin), or gate .expiredCollect on the marker having been perceptibly expired across ≥7d of the GC-ing device's own elapsed time since first sight (age at first sight is skew; growth since sight is skew-free). At minimum, correct rows 14/15 and the property carve-out from '>14d' to '>7d'.

### cloudkitOps-4 [weakens] Hold-set trigger is underspecified for per-record fetch failures and decode-nil markers — the natural implementation (mirroring existing .success-only code) leaves a device unprotected while its query returned the marker's recordID

**Violated:**

A2's guarantee that 'no watermark state, clock skew, or crash history can leave a device unprotected while a marker it can see exists' — the device's query literally returned the marker's recordID. Safety property via the row-20 deletion path without row-20's precondition.

**Interleaving:**

Origin wiped the zone at T; marker M is present. (1) Device B syncs at T+1m: pullResetRequests' query SUCCEEDS but returns [(M.recordID, .failure(...))] — a per-record fetch failure, which does not throw — or M's record decodes nil in SyncResetRequest(from:) (corrupt write, or a record from a future client). The spec says holds are set 'whenever its query result contains any SyncResetRequest record — regardless of classification', but classification presupposes a decoded request; the existing code pattern (pullResetRequests, ProfileSyncManager.swift:382-384) inspects only .success + decoded records, so the obvious port sees 'no markers', sets no hold, and returns normally. (2) The pass continues to pullProfiles, which returns the mid-wipe partial set {P1}. (3) handleSyncedProfiles: remoteIds non-empty, hold nil → reconciliation deletes P2..Pn locally. Unlike accepted row 20, this needs NO index-lag invisibility of the marker — the marker was returned by the query; only its payload fetch/decode failed.

**Verifier's suggested fix (historical; superseded by #267):**

Specify explicitly (and test): holds are set when the SyncResetRequest query returns ANY recordID for that record type — success, per-record failure, or decode-nil — exactly mirroring how allRemoteProfileIds is built from recordIDs before decode filtering in pullProfiles.

### cloudkitOps-5 [weakens] Stale-presence pulls can clear the hold while the zone is genuinely wiped — the Interplay claim ('protects every device that ever saw one, for exactly as long as the zone lacks data') and row 20's precondition ('marker never sighted') are both overstated

**Violated:**

Honesty of row 20's acceptance and of the Interplay paragraph ('A2 protects every device that can see the marker (or ever saw one), for exactly as long as the zone lacks data that device could restore — and not a pass longer'). Protection can end while the zone still lacks the data.

**Interleaving:**

(1) Origin A resets at T: marker M saved, wipe completes. (2) B pass1 at T+2m: sights M → hold set; its pullProfiles is served by a stale index replica showing the full pre-wipe set → read-verification passes → hold CLEARED (and same-pass reconcile deletes nothing) — although the zone truly contains none of B's data. (3) B pass2 at T+10m: pullResetRequests hits a replica that has not indexed M (stale absence — permitted arbitrarily) → no sight, no hold; pullProfiles returns the true partial state {P1} (A mid-re-push) → hold nil → B deletes P2..Pn, including B-only profiles = permanent loss. B DID sight the marker, so row 20's stated precondition ('marker never sighted by this device') is not required; the true requirement is only 'no hold present and marker not sighted in the reconciling pass', which a stale-presence verification-clear can manufacture after a sight. Net damage window is the same index-lag class as accepted row 20, so this is an honesty defect rather than a new mechanism — but the design's central 'holds latch until the zone is provably healthy' story is not what the mechanism delivers: verification trusts a single possibly-stale read, and holds do not latch.

**Verifier's suggested fix (historical; superseded by #267):**

Reword row 20 and Interplay to the true precondition ('no hold and no sight in the reconciling pass; sights do not latch because verification may pass on a stale-presence read'). Optionally harden: only clear a hold when the verifying pull is at least N seconds newer than the hold's set-time, or require the marker to have been sighted in the same pass that verifies (markers persist 14d, so a healthy verifying pass normally sees it; a marker-absent + full-superset pass is exactly the stale-read signature).

### cloudkitOps-6 [weakens] Row 16 / backstop honesty: loss does not require 'the push keeps failing' — the first successful push after backstop expiry can be eaten by ordinary index lag, on the design's own axiom; gcTTL == backstop (14d) removes marker re-sight protection at exactly the worst moment

**Violated:**

Honesty of row 16's accepted residual (its stated precondition — persistent push failure — is not required), and internal consistency with the constraint 'no safety decision may rely on a write being query-visible'.

**Interleaving:**

(1) B's pushes of profile X (syncVersion>0) fail for 14 days (e.g., app killed before the detached pushTask completes each pass). The hold set at reset time T never verifies (X absent from every pull). (2) At T+14d the backstop pass clears the hold and skips reconciliation; this pass's end-of-pass push of X SUCCEEDS (network recovered). (3) Around the same time, marker M reaches gcTTL (also 14d) and is GC'd — so no re-sight can re-arm the hold. (4) Next pass at T+14d+10m: no marker → no hold; pullProfiles does not yet show the minutes-old X write (the design's own constraint: 'a write this device just made (even server-acked) may be missing from the next query') → remoteIds non-empty, missing X → X deleted locally; selections and session history lost, husk re-created later. Row 16 accepts residual loss only 'if the push keeps failing'; here the push succeeded. The backstop's stated safety story ('the end-of-pass push then restores anything missing before the next pass reconciles') relies on write→query visibility, which the design elsewhere forbids as a safety dependency.

**Verifier's suggested fix (historical; superseded by #267):**

State the acceptance honestly (loss also occurs if the finally-successful push is not yet query-visible at the first post-backstop reconcile). Mechanically: make gcTTL strictly greater than the hold backstop (e.g., 21d vs 14d) so a live marker re-arms the hold after backstop expiry, and/or have the backstop pass arm a one-pass grace (skip reconciliation for one additional verified-or-not pass).

### cloudkitOps-7 [nit] SharedData reset state (watermark, holds) is not iCloud-account-scoped: after account switching, a stale watermark silently suppresses the new account's reset delivery

**Violated:**

Liveness: 'resets reach every device syncing within 7 days' for the post-switch account; the design is silent on account scoping despite persisting cross-account state.

**Interleaving:**

(1) On account A1, B processes a reset at T1 → lastProcessedResetAt ≈ T1. (2) User switches to account A2 (different private DB/zone). A2's zone contains a live reset marker with effectiveDate T0 < T1. (3) B syncs A2's zone: marker sighted → hold set (safe), but classify → .skipAlreadyProcessed against A1's watermark → the reset's selection-clearing is never applied on B, permanently, with no indication. Conversely, a stale hold from A1 defers deletion propagation on A2 until verification passes there. Fails safe for data (holds only ever block deletions) — delivery/UX miss only. The codebase already has the per-account pattern (legacyCleanupKey(for: userRecordName)).

**Verifier's suggested fix (historical; superseded by #267):**

Key lastProcessedResetAt and both reconciliation holds by userRecordID (as legacy cleanup already does), clearing or namespacing them on account change.

## Lens: specReview — verdict: has-holes

**Verifier reasoning:**

> Read the full REVISION 3 spec (361 lines) plus the actual source it's built against: Foqos/CloudKit/SyncCoordinator.swift (handleSyncedProfiles, handleSyncedLocations, pushLocalData, handleSyncReset), Foqos/CloudKit/ProfileSyncManager.swift (resetSync, pullResetRequests, performFullSync, deleteAllSyncedData, pushLocation/pushSyncedLocation), Foqos/Models/SavedLocation.swift, and Packages/FoqosShared/Sources/FoqosShared/SharedData.swift. Verified every line-number citation in the spec's Problem section against current main (all accurate — resetSync:823/831/839, pullResetRequests:345/402/387, pullProfiles:348, handleSyncedProfiles guard:179/195, handleSyncedLocations:479-499, deleteAllSyncedData chunking:873, isNewerSchemaVersion filters:64/567 — all match, so the factual re-verification claims in the Problem section hold up).
> 
> No literal placeholders/TBDs exist (only an unrelated use of the English word "placeholders" at line 313).
> 
> Cross-checked every row of all four interleaving tables (rows 1-22) against A1-A4/B1-B5 and the data-flow diagram; most are internally consistent. Two genuine problems surfaced:
> 
> (a) Invariant (I) says a device "may reconcile deletions only in a pass whose own pull proves the zone contains every record this device could re-create" — evidence must be "read in the same pass." But the hold is modeled as single global per-device SharedData state, read fresh "inside the reconciliation branch, never captured at pass start" (A2). ProfileSyncManager.performFullSync() has no re-entrancy guard (confirmed: no `isSyncing` check at entry, just an unconditional `self.isSyncing = true`), and SettingsView's "Sync Now" button plus notification-triggered handleRemoteNotification can both invoke it independently — the spec's own table acknowledges concurrent passes occur (rows 5, 10). Under that acknowledged concurrency, a pass with a stale/incomplete pull can observe hold==nil because a *different*, more-current concurrent pass satisfied read-verification and cleared it moments earlier — then reconcile against its own stale pull without ever itself proving the superset. That is a different pass's evidence deciding, which directly contradicts "read in the same pass, decides." No interleaving row analyzes this specific case (row 5/10 only cover holds staying *set* during concurrent passes, not one pass benefiting from another's clear).
> 
> (b) A2's Backstop bullet and two other spots (test-plan item 4's 4th bullet, row 16) all state the 14-day-expired-hold case "clears... and that pass still skips reconciliation." But the Data-flow diagram's literal reconciliation formula is `deletion reconciliation IFF remoteIds nonempty AND (hold nil OR remoteIds ⊇ local restorable ids → clear hold, reconcile)` — a two-way disjunction with no third branch for "hold was set-but-expired → clear anyway but still skip." As written, once the backstop clears the hold, "hold nil" is true and the diagram's own formula says reconcile — contradicting the prose. The diagram doesn't show which component performs the backstop check either (pullResetRequests' diagram bullets only cover marker GC, not hold GC), so it's genuinely unclear where/how the "clear-but-skip" branch is meant to be structured.
> 
> Checked the location syncVersion mechanics specifically requested: handleSyncedLocations sets `existingLocation.syncVersion = max(existingLocation.syncVersion, 1) + 1` only on remote-newer update, and `= max(existingLocation.syncVersion, 1)` (no +1) on "seen from remote, not newer." Crucially, pushLocation/pushSyncedLocation (ProfileSyncManager) never touch local `location.syncVersion` — unlike pushProfile (SyncCoordinator:610, `profile.syncVersion += 1` before the network call). So for locations, syncVersion > 0 is set *only* by pull-confirmed evidence (this device's own push reflecting back, since handleSyncedLocations has no origin-device filter, unlike handleSyncedProfiles' line 117 check), whereas for profiles it's set optimistically by the *push attempt itself*. The spec (A2) states the profile and location superset predicates as parallel ("local profiles with syncVersion > 0 ... local locations with syncVersion > 0") and the test plan (item 5) calls the location tests a "mirror of (4) minus the schema case" — but no test explicitly exercises the location-only "seen from remote, not updated" merge path, despite it being the specific mechanism that governs when a location becomes eligible for the superset check at all.
> 
> Checked "same-pass clear-then-reconcile when profile hold clears but location hold doesn't": SavedLocation has no SwiftData `@Relationship` to BlockedProfiles (geofenceRule is a plain Codable struct, not a relationship), and handleSyncedProfiles/handleSyncedLocations read/write entirely separate SharedData keys with no cross-references in the code paths — so this particular coupling is actually well-defined; I did not find a contradiction here specifically (documenting a negative result, not raising it as a finding).
> 
> Checked SharedData.swift: existing pattern wraps every compound check-then-set operation (deviceSyncId generation, snapshot map mutations, session snapshot mutations) in a cross-process POSIX-flock `withLock`. The spec introduces three new keys with explicitly compound, TOCTOU-prone semantics ("Set... only if currently nil", conditional clearing) but the word "lock" never appears anywhere in the design doc, and no locking/atomicity discipline is specified for the new keys, despite SharedData.swift being listed as an in-scope file.
> 
> Checked exact comparison-operator boundaries: B2 says "Requests older than processTTL = 7 days are not processed" and B3 says "deletes markers older than gcTTL (14 days)" — "older than" is used for both, but the spec never states whether age==7d/14d exactly falls on the process/skip side or the skipExpired/expiredCollect side (`<` vs `<=`). Test-plan item 1 claims "boundaries at exactly 7d/14d" will be tested, but since the doc never states the correct classification at those exact boundaries, the test's own expected assertions are undefined by the spec as written.
> 
> Overall verdict: has-holes. The two breaks-safety items are grounded in an acknowledged design premise (concurrent passes exist) combined with real code facts (no re-entrancy guard) and a literal reading of the diagram vs. prose; the remaining items are real ambiguities that a competent implementer would have to resolve by guessing, undermining the doc's own "extract every decision into pure, injectable-now helpers" and "positive evidence... never classification state" commitments.

### specReview-1 [breaks-safety] Global per-device hold lets a stale concurrent pass reconcile on another pass's evidence

**Violated:**

Invariant (I), lines 105-108: 'a device may reconcile deletions only in a pass whose own pull proves the zone contains every record this device could re-create. Positive evidence, read in the same pass, decides — never push acks, never timers alone, never classification state.' Pass A's decision here is decided by Pass B's evidence, not its own, in the same pass.

**Interleaving:**

Pass A (e.g. triggered by a remote CK notification) starts pulling profiles while a reset's re-push is still landing; its `remoteProfileIds` snapshot is missing a record R that this device holds. Concurrently, Pass B (e.g. the user taps 'Sync Now' — `SettingsView.swift:176` calls `profileSyncManager.performFullSync()` directly, and `ProfileSyncManager.performFullSync()` at `ProfileSyncManager.swift:337` has no re-entrancy guard: it unconditionally sets `self.isSyncing = true` with no check that a sync is already running) runs slightly later, after R has fully landed, and its own pull proves the superset — Pass B clears `profileReconciliationHoldSince` per A2's read-verification rule and reconciles safely using Pass B's own (complete) pulled set. Because 'The hold is read fresh (from SharedData) inside the reconciliation branch, never captured at pass start' (spec lines 141-143), if Pass A reaches its own reconciliation branch after Pass B's clear, Pass A reads hold==nil and — per the diagram's own formula '(hold nil OR remoteIds ⊇ local restorable ids → clear hold, reconcile)' (lines 246-248) — proceeds to reconcile using Pass A's own stale, incomplete `remoteProfileIds`, deleting local profile R even though it currently exists in the zone.

**Verifier's suggested fix (historical; superseded by #267):**

Rows 5 and 10 of the interleaving table assert concurrent passes are safe but only analyze the case where the hold stays set throughout; neither row (nor any other) analyzes the cross-pass 'one pass's clear leaks into another pass's stale reconciliation' interleaving. This needs to be added to the interleaving table and resolved (e.g. by making the hold-clear-and-reconcile decision per-pass-local rather than a globally shared SharedData boolean) before implementation, since `performFullSync` genuinely has no re-entrancy guard today.

### specReview-2 [breaks-safety] Backstop's 'clear but still skip' behavior contradicts the data-flow diagram's reconciliation formula

**Violated:**

A2 Backstop bullet (lines 152-154) vs. the Data-flow diagram (lines 244-248); also Invariant (I)'s 'never timers alone' framing, since a diagram-literal implementation would let a 14-day timer expiry alone trigger reconciliation against unverified data on that pass.

**Interleaving:**

A hold has been set for >14 days (superset proof has never succeeded — e.g. row 16's persistently-failing re-push). Per A2's Backstop bullet (lines 152-156): 'a hold older than `SyncResetRequest.gcTTL` (14 days...) is cleared **and that pass still skips reconciliation**.' Test-plan item 4's fourth bullet (line 337) and row 16 (line 283) both restate the same 'cleared, but still skipped this pass' outcome. But the Data-flow diagram's literal reconciliation gate (lines 244-248) is: `deletion reconciliation IFF remoteIds nonempty AND (hold nil OR remoteIds ⊇ local restorable ids → clear hold, reconcile) AND skipping isNewerSchemaVersion + syncVersion==0 profiles.` This is a two-way disjunction with no third arm for 'hold was set-but-backstop-expired.' If the backstop clears the hold before/at the point this formula is evaluated, `hold nil` is true and the diagram says reconcile — using this device's own (already known-incomplete, per row 16) pulled set — which is exactly the outcome A2's prose says must NOT happen on the backstop-expiry pass.

**Verifier's suggested fix (historical; superseded by #267):**

The diagram never states which component performs the 14-day hold-expiry check (pullResetRequests' diagram bullets at lines 240-243 only show marker GC — a different 14-day check on `SyncResetRequest` records, not on the hold timestamps) or how a 'cleared but not reconciled' outcome is distinguished in code from a 'cleared and reconciled' outcome. The diagram needs an explicit third branch (or the backstop needs to be modeled as leaving reconciliation gated by an independent flag, not solely by hold==nil) before this can be implemented consistently with the prose.

### specReview-3 [weakens] "Local restorable ids" means mechanically different things for profiles vs. locations, but the test plan treats location tests as a plain mirror

**Violated:**

Consistency between A2's parallel phrasing for profiles/locations and the actual mechanism in `SyncCoordinator.swift`; test-plan completeness for item 5 relative to the claimed #195.5 location fix.

**Interleaving:**

For profiles, `SyncCoordinator.pushProfile()` (`SyncCoordinator.swift:610`, `profile.syncVersion += 1`) sets syncVersion>0 optimistically at push-attempt time, before any network confirmation. For locations, neither `pushLocation` nor `pushSyncedLocation` (`ProfileSyncManager.swift:623-666`) ever touches local `location.syncVersion` — it is set to >0 *only* inside `handleSyncedLocations` on receipt from a pull: `existingLocation.syncVersion = max(existingLocation.syncVersion, 1) + 1` when remote is newer (`SyncCoordinator.swift:441`), or `existingLocation.syncVersion = max(existingLocation.syncVersion, 1)` when merely 'seen from remote' without being newer (`SyncCoordinator.swift:454`) — and `handleSyncedLocations` has no origin-device filter (unlike `handleSyncedProfiles`'s `if syncedProfile.originDeviceId == deviceId { continue }` at line 117), so a location only becomes 'restorable' once this device's own push has round-tripped back through a subsequent pull. A2 states the profile predicate ('local profiles with syncVersion > 0 and !isNewerSchemaVersion', lines 145-146) and the location predicate ('local locations with syncVersion > 0', lines 149-150) as parallel statements, and test-plan item 5 (line 341) says location gating tests are simply a 'mirror of (4) minus the schema case.' No listed test case exercises the location-specific 'seen from remote, not newer' merge path (the bare `max(syncVersion,1)`, no +1) that is unique to how a location's restorable-status is established.

**Verifier's suggested fix (historical; superseded by #267):**

State explicitly in A2 (or a dedicated note) that location syncVersion semantics are pull-confirmed-only (not push-optimistic like profiles), and add an explicit test case for the 'seen from remote but not updated' merge path feeding the superset check, rather than folding it into an unqualified 'mirror of (4)'.

### specReview-4 [weakens] No locking/atomicity discipline specified for the three new SharedData keys

**Violated:**

No specific mechanism name is violated — this is an omission relative to the doc's own file scope and the codebase's established SharedData concurrency-safety convention.

**Interleaving:**

A2/B1 introduce three new compound, check-then-act SharedData operations: 'Set (to local now, only if currently nil)' for both holds (lines 131-133), and the per-device processed watermark advance (B1, lines 184-189). `SharedData.swift`'s existing pattern wraps every comparable compound operation (deviceSyncId generation at lines 469-481, all snapshot/session mutations) in `withLock`, a cross-process POSIX `flock` explicitly built for 'compound UserDefaults operations' (`SharedData.swift:69-74`). The word 'lock' does not appear anywhere in the design doc (grep confirms zero matches beyond unrelated clock/keep-data language), and `SharedData.swift` is listed in the spec's Files header as an in-scope file to modify.

**Verifier's suggested fix (historical; superseded by #267):**

Specify whether the new `set-if-nil` and `clear` operations on the two hold keys, and the watermark advance, must be wrapped in `withLock` (matching existing SharedData conventions), and clarify whether the same-process MainActor interleaving discussed in the concurrent-pass finding above is intended to be the only protection, or whether additional atomicity is required.

### specReview-5 [weakens] processTTL/gcTTL boundary comparison operators (7d, 14d) are never pinned down

**Violated:**

Design constraint 'extract every decision into pure, injectable-now helpers that are unit-testable' (Constraints section) — a boundary that isn't specified can't be correctly unit-tested, only arbitrarily coded and then retroactively asserted.

**Interleaving:**

B2 (line 193): 'Requests older than `processTTL = 7 days` are not processed.' B3 (line 197): 'Any device deletes markers older than `gcTTL` (14 days...).' Both use 'older than' without stating whether age exactly equal to 7d/14d falls on the processed/kept side or the expired/GC'd side (i.e. `age > 7d` vs `age >= 7d` for the process/skipExpired boundary, and similarly for skipExpired/expiredCollect at 14d). Test-plan item 1 (lines 323-326) explicitly lists 'boundaries at exactly 7d/14d' as something that will be tested, but since the spec gives no ground-truth classification for those exact instants, the boundary tests' own expected assertions are undefined by the design as written.

**Verifier's suggested fix (historical; superseded by #267):**

State the exact inequality direction for both boundaries (e.g. 'processed iff age <= 7d', 'GC iff age > 14d') so the classify() truth table and its tests have an unambiguous target, consistent with the 'fail toward keep data / keep marker' clock-skew principle already stated in the Constraints section.
