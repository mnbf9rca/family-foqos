# A1 adversarial verification — round 3 findings (verbatim)

- **Target design:** rev 4 (time-boxed suppression + id idempotency)
- **Context:** acceptance corpus for #267; see `2026-07-02-reset-sync-a1-acceptance-corpus.md`.
- **Provenance:** machine-extracted, unedited output of the independent verifier agents.

## Lens: temporal — verdict: has-holes

**Verifier reasoning:**

> Human Meatbag — adversarial verification of rev 4, temporal-arithmetic lens, verdict: has-holes.
> 
> What I verified holds: (a) the identity-based processed map genuinely kills the rev-3 reprocessing loop in every clock configuration I could construct — future-clamped bases, slow/fast receivers, roll-forward/roll-back — every reprocess cycle costs >= 21d of local clock and terminates (worst case exactly one extra clear for >14d-slow clocks, finding 4; never unbounded); (b) marker-before-wipe with suppression+own-id persisted at step C.2 closes every resetSync crash row I attacked (rows 1-7 check out, including double-reset marker survival via B6 and chunked <=400 deletes); (c) B5's suppress-on-sight -> dispatch -> mark-last ordering is crash-safe in the claimed direction at every SIGKILL point (rows 8-9); (d) monotonic max-only suppression is immune to concurrent-pass downgrades; (e) the GC margin arithmetic (21d - 7d = 14d) is now stated correctly; (f) account-switch reasoning holds (UUIDs can't collide; carried suppression blocks only deletions).
> 
> What breaks: the core temporal defect is that A1 anchors suppression to the marker's effectiveDate (window = effectiveDate+8d for every sighter), not to each device's first contact. The devices most at risk — stragglers first syncing at age 7-21d, whose data nobody else re-pushed since the wipe — therefore receive between <1 day and exactly ZERO protection from sighting the marker, while the same pass's pull-before-push ordering deletes their syncVersion>0 profiles before pushLocalData can restore them. Rows 11, 14 and 20 all assert 'sight => suppressed/protected', which is arithmetically false at first sight age >= 8d local; that makes finding 1 a reportable safety break, not an accepted residual (rows 20/23 preconditions — 'never sighted' / '>=8d continuous push failure' — do not cover it; the marker IS sighted and no push failure is required, just an 8-day sync gap spanning the reset, e.g. new-phone reset + old phone in a drawer). Note also that re-sighting a decodable marker NEVER extends protection (min(basis,now)+8d with basis=effectiveDate is a no-op after day 8), so row 23's 'no marker re-sight' precondition is mechanically meaningless.
> 
> Second, the undecodable-marker path (row 16) combines 'basis=now on every sight' with 'no GC without decode' into unbounded per-device suppression plus an immortal marker: any normally-syncing device never exits suppression, deletion propagation dies family-wide, and every explicit profile delete resurrects via other devices' every-pass re-push — a direct violation of three stated liveness requirements, fixable cheaply because CKRecord.creationDate is system metadata available without custom-field decode.
> 
> Findings 3-6 are honestly-graded weakeners/nits: forward clock rolls defeat the active window (the gate fails toward delete, contradicting the design's own fail-toward-keep constraint and its child-adversary clock model — unstated residual); the 21d prune vs 21d GC symmetry leaves a >14d-slow twin of the accepted >14d-fast residual unstated (one extra selection-clear of a ~3-week-old reset); B5's last-reset-wins is only intra-pass under the spec's own query-staleness assumption; and marking ids processed when the dispatch no-ops (nil modelContext) can permanently forfeit delivery on a device.
> 
> I did not re-report the accepted residuals (14 fast-clock GC, 20, 22, 23, intentional-behaviour changes) except where their stated preconditions are provably wrong, as licensed: rows 11/14/20 (protection-by-sight claims, finding 1) and rows 13/15 ('processed once', finding 4). Files: docs/superpowers/specs/2026-07-02-reset-sync-safety-design.md verified against pre-fix Foqos/CloudKit/ProfileSyncManager.swift, Foqos/CloudKit/SyncCoordinator.swift, Foqos/CloudKit/SyncModels.swift (pull-before-push pass ordering, per-item swallowed push errors, push-optimistic profile syncVersion, pull-confirmed location syncVersion, and the isNewerSchemaVersion filters all confirmed in code and load-bearing for the timelines above).

### temporal-1 [breaks-safety] Suppression is born expired for markers first sighted at local age >= 8d (rows 11/14/20 claim protection that does not exist)

**Violated:**

SAFETY property: local BlockedProfiles/SavedLocation deleted with no genuine remote deletion. Not covered by accepted residuals, whose stated preconditions are wrong: row 11 claims '7-21d: .skipExpired ... but sighted => suppressed — protected while others converge' (false: sight of a >=8d-old marker yields an already-expired window; 7-8d yields <1d); row 14 claims '<=14d fast: ... sight => suppression still protects its data' (false for small fast skews near day 7-8); row 20's own framing 'one sight suppresses for 8 days' is false — one sight suppresses until effectiveDate+8d, which can be zero time. Root cause: A1's basis for decodable markers is effectiveDate, so the window is anchored to the reset, not to the at-risk device's first contact — yet devices first contacting at age 7-21d are exactly the stragglers whose data nobody else re-pushed.

**Interleaving:**

All clocks accurate; no failures needed beyond an 8-day sync gap. Family {O: newly-added phone, D: primary phone}. T-30d..T-1d: D creates and pushes profiles P1..Pn (syncVersion>0 on D). T0-1h: user enables sync on O; O's initial pull is incomplete (user is resetting precisely because sync looks broken). T0: user runs resetSync on O: marker M saved (server creationDate=T0), O suppressed, zone wiped, O re-pushes only its own local set, which lacks some/all Pi. D is in a drawer from before T0 until T0+8d (vacation, kid's spare iPad — routine). T0+8d+1h: D syncs. pullResetRequests sights M and calls extendSuppression(effectiveDate=T0): suppressedUntil = max(nil, min(T0, now)+8d) = T0+8d, which is ALREADY IN THE PAST — zero protection. classify: age 8d1h > 7d => .skipExpired, so no dispatch and no reset re-push either. Same pass continues: pullProfiles returns O's non-empty set; now >= suppressedUntil; reconciliation deletes every local Pi with syncVersion>0 absent from remote — and this runs BEFORE didRequestLocalDataPush/pushLocalData at the end of the pass, so D's own every-pass push can never rescue them. Sole-held Pi (and their sessions/selections) are permanently destroyed; SavedLocations die identically. Variant needing only ~26h of unavailability: D syncs once at T0+7d-1h (age 7d => .process, suppression = T0+8d = 1h+... left), SIGKILLed before the queued pushTask executes, next syncs at T0+8d+1h => same self-wipe. Fast-clock variant: a receiver merely 2d fast sighting at real T0+6d computes local age 8d => .skipExpired AND suppressedUntil=T0+8d <= now_local => zero protection inside the nominal delivery window.

**Verifier's suggested fix (historical; superseded by #267):**

Extend suppression from NOW on FIRST sight of each marker requestId (persist a sighted-ids map alongside processedResetRequestIds, same 21d-class prune): suppressedUntil = max(cur, now + 8d), applied at most once per requestId per device. This preserves boundedness (a single marker extends each device at most once, ~8d; re-extension only possible after a 21d prune) and gives every device a full window from its own first contact, closing both the age>=8d zero-window and the age~7d thin-window cases. Then honestly document the remaining cross-device slack residual: a copy-holding device whose own window ends may delete its COPIES while a day-7 processor is still converging — bounded, non-permanent (originals re-pushed later, recreated with needsAppSelection=true).

### temporal-2 [breaks-liveness] A single undecodable marker extends suppression unboundedly and is never GC'd — deletion propagation permanently dead, profiles become undeletable

**Violated:**

LIVENESS: 'suppression cannot be extended unboundedly by any single marker' (violated directly: basis=now on every sight), 'markers GC'd eventually' (no GC path exists for undecodable markers), 'deletion propagation resumes after windows close' (windows never close). Row 16's outcome column says only 'Protected. No processing, no GC' — it hides that 'no GC' + 'basis now on every sight' compounds into permanent family-wide suppression; not an honestly-stated residual.

**Interleaving:**

One SyncResetRequest record exists that fetches but never decodes (corrupt/missing guarded field, or a future app version that renamed requestId/requestedAt/clearRemoteAppSelections/originDeviceId — a case A1 explicitly embraces: 'a corrupt or future-schema marker still protects'). Every pass on every device: pullResetRequests sights the raw recordID => extendSuppression(basis=now) => suppressedUntil = now+8d. Any device syncing at least every 8 days (i.e., any normal device) keeps its own suppression alive FOREVER. GC cannot fire: B3/B4 GC is 'classify all decoded; age>21d => GC-delete' and age requires effectiveDate, which requires decode — an undecodable marker has no GC path on any device, ever. Consequence chain: user deletes a profile on device A (explicit CK delete succeeds); devices B/C never apply the absence-inference (suppressed forever) and re-push their local copies every pass; the zone record resurrects; A re-pulls it as an upsert. The user cannot delete any profile, family-wide, permanently.

**Verifier's suggested fix (historical; superseded by #267):**

For fetched-but-undecodable records (.success with failed init), use CKRecord.creationDate — system metadata present on every server-fetched record regardless of custom-field decode — as the effectiveDate for BOTH the suppression basis and GC eligibility; such markers then suppress until creationDate+8d and are GC'd at age>21d like any other. For per-record .failure results (no record object at all), persist a first-sighted-at date per recordID locally; stop extending suppression and permit GC-by-recordID once first-sight + gcTTL passes.

### temporal-3 [weakens] Forward clock roll during an active suppression window re-opens the #195 wipe (gate fails toward delete, violating the design's own fail-toward-keep constraint)

**Violated:**

Design constraint 'every clock-dependent rule must fail toward keep data' — the gate `now >= syncDeletionSuppressedUntil` fails toward delete under forward skew/jumps. Unstated residual: row 14 covers fast clocks only for GC (>14d), the intentional-behaviour-changes section describes the window as '~8 days' with no clock caveat. If 'skew up to days' in the safety property includes 8d, this is a property violation; at minimum it must be listed as a residual with honest preconditions (forward jump >= remaining window + a not-yet-re-pushed record).

**Interleaving:**

T0: reset; device R sighted the marker at T0 (suppressedUntil=T0+8d), processed it, but the re-push of R's sole-held profile Q item-failed (error swallowed by rePushLocalSyncedData's per-item catch). T0+1d: R's clock is set forward 8+ days — the design's stated threat model is children manipulating clocks, and the safety property requires tolerating 'clock skew up to days'. R syncs: A2's gate reads now_local >= T0+8d => passes; remote is non-empty (origin's data), Q absent => R deletes Q locally, before the end-of-pass push could restore it. Q is permanently lost. Also prunes are unaffected but the same jump would defeat ANY device's window mid-reset (deleting its local copies of not-yet-re-pushed profiles of other devices — recoverable but destroys selections/session history).

**Verifier's suggested fix (historical; superseded by #267):**

Cannot be fully fixed with local clocks (inherent to time-boxed suppression); mitigate and document: persist a monotonic last-observed-now in SharedData and treat a forward jump larger than elapsed wall-time-plausible bounds as 'suppressed' for the gate (fail toward keep), and/or gate reconciliation additionally on 'this device has completed at least one successful push pass since its last marker sight'. At minimum add an honest residual row: a forward-rolled clock defeats suppression.

### temporal-4 [weakens] processed-id prune (21d local) erases memory while a marker is still locally fresh for >14d-slow clocks — second selection-clear of an objectively ~3-week-old reset; rows 13/15's 'processed once' is overstated

**Violated:**

Safety exception (b) permits selection-clearing only of an 'unexpired (<=7d) reset' — server age here is ~21d. Rows 13/15 state 'processed once — id-idempotent, no loop possible by construction' unconditionally; the >14d-SLOW residual is unstated, asymmetric with the honestly-stated >14d-fast GC residual (row 14). Precondition is pathological (>14d slow clock AND marker surviving >21d real) but must be stated, exactly as the fast twin is.

**Interleaving:**

Receiver R is 15d slow (now_R = real - 15d). Marker M created at server time e; origin O goes offline right after (GC never runs; GC failures are also 'ignored, retried'). Real e+1h: R fetches M; effectiveDate=e > now_R => age clamps to 0 => .process => clears selections (flag set), processedResetRequestIds[M] = now_R = e-15d. Real e+21d+6h: R's pass prunes M's id (now_R - processedAt = 21d6h > 21d). M is still fetchable (nobody GC'd it; R's own GC needs LOCAL age > 21d but local age = now_R - e = 6d6h). classify: unprocessed (pruned), local age 6d6h <= 7d => .process => R re-dispatches didReceiveSyncReset and RE-CLEARS every profile's selectedActivity for a reset that is objectively 21+ days old — needsAppSelection set family-profile-wide on R, blocking silently stops until manually reconfigured. No infinite loop (next cycle: local age > 7d => .skipExpired, then local GC at 21d) — the id-map does kill the rev-3 loop — but 'once' becomes 'twice'. Boundary arithmetic: safe for slowness <= 14d exactly (processedAt >= e - s; need s <= pruneTTL - processTTL = 14d), broken beyond.

**Verifier's suggested fix (historical; superseded by #267):**

Prune processedResetRequestIds at pruneTTL = gcTTL + processTTL = 28d (or simply 'never prune an id while any live marker with that recordID is still being sighted'). With 28d: processedAt + 28d >= effectiveDate - s + 28d >= effectiveDate + 7d local-freshness horizon for all s <= 21d, restoring a margin at least as wide as the fast-clock one. Then add the symmetric residual row for >21d-slow clocks.

### temporal-5 [nit] B5's 'superseded reset intent is dropped' only holds intra-pass; CKQuery staleness can apply an older reset after a newer one

**Violated:**

B5's stated guarantee ('last reset wins; older ones retired-without-applying') is not actually guaranteed under the spec's own query-staleness assumption; it holds only when both markers appear in the same pass.

**Interleaving:**

resetSync retried (row 7) => two live markers M1 (older) and M2 (newer), both <= 7d, both flag=true. Device pass 1: stale query returns only M2 => M2 processed (selections cleared, marked). Pass 2 hours later: differently-stale query returns only M1 (staleness in both directions is an explicit assumption) => M1 is unprocessed and the newest .process candidate IN THIS PASS => dispatched => the superseded reset's selection-clear is applied after the newer reset already ran, contradicting B5's 'selection-clearing intent of a superseded reset is intentionally dropped'. Both resets are genuine and unexpired, so this stays inside safety exception (b) — documentation/robustness nit only.

**Verifier's suggested fix (historical; superseded by #267):**

Persist latestProcessedResetEffectiveDate (monotonic max, SharedData); classify any candidate with effectiveDate <= that value as .skipAlreadyProcessed-equivalent (retire and mark its id). Or soften the B5 wording to 'dropped when observed together'.

### temporal-6 [nit] B5 marks requestIds processed even when the dispatch no-ops (nil modelContext guard) — permanent delivery loss for that device

**Violated:**

LIVENESS: 'delivery to every device syncing within 7d' — broken for a device whose first post-reset pass precedes context wiring. B5 assumes the dispatch's synchronous part succeeded; the spec never conditions marking on application.

**Interleaving:**

A remote-notification- or setup-triggered performFullSync runs before SyncCoordinator.setModelContext has been called (app cold-start ordering). pullResetRequests classifies a fresh marker .process, dispatches didReceiveSyncReset — handleSyncReset hits `guard let context = modelContext else { return }` and does NOTHING (no selection clear, no re-push chain) — then step B5.3 unconditionally marks the requestId processed. Every later pass: .skipAlreadyProcessed. The reset is never applied on this device; delivery permanently lost (suppression was still extended on sight, so no data-safety impact). Whether this ordering is reachable depends on app wiring outside the three reviewed files — the current code sets the delegate in SyncCoordinator.init and setModelContext separately, so the spec should not assume dispatch always applies.

**Verifier's suggested fix (historical; superseded by #267):**

Have didReceiveSyncReset return whether it actually applied (context present, clear+chain executed); mark requestIds processed only for applied dispatches (re-dispatch next pass otherwise — idempotent, the safe direction B5 already relies on for the crash-before-mark case).

## Lens: stateMachine — verdict: has-holes

**Verifier reasoning:**

> Human Meatbag — I read the rev-4 spec in full and re-traced the pre-fix code (ProfileSyncManager.swift resetSync:823 / pullResetRequests:373 / performFullSync:337; SyncCoordinator.swift handleSyncReset:529, pushTask chain :552-560/:620-648, reconciliation :179-201/:479-499; SyncModels.swift SyncResetRequest; SharedData withLock; FoqosApp.swift wiring :227/:341).
> 
> What HELD under attack (stating so per instructions): (1) the monotonic never-cleared suppression date genuinely kills every clear-race class from revs 2-3 — stale-presence, stale-absence-re-arm, concurrent-pass clear leaks, ack/wipe races (rows 5, 8, 9, 10 verified statement-by-statement, including SIGKILL between B5.2's context.save and B5.3's SharedData write: relaunch re-processes, idempotent direction). (2) Marker-before-wipe plus wipe-excludes-SyncResetRequest-entirely closes #195.3 and the dual-reset marker-annihilation; resetSync retries after step-1-success/step-3-failure leave multiple live markers and multiple bases safely (max of bounded bases; newest-wins retires older ids). (3) The id map truly kills the rev-3 infinite loop in every STATIC clock configuration including basis clamping: under any constant skew, by the time an entry can prune (21 local days), the marker's local age is ≥ 21d−s, so re-processing requires s ≥ 14d slow and is bounded at ~⌈(s−14d)/21d⌉+1 applications — finite, never infinite; only unbounded active clock oscillation (plus GC failure/marker survival) yields unbounded re-clears. (4) The pushTask chain cannot deadlock (the follow-up performFullSync spawns later chain links without awaiting them) and the 5-minute notification throttle cannot cause a device to miss all sightings beyond the accepted row-20 staleness class (markers persist ~21d; any unthrottled pass sights). (5) GC margin arithmetic now checks out (21d − 7d = 14d, fixing rev 3's error). (6) Locations differ from profiles only in pull-confirmed syncVersion and the missing schema clause — both make locations strictly safer; no location-specific hole. (7) Account-switching claims verified as stated.
> 
> What BROKE: the single load-bearing arithmetic flaw is anchoring suppression at the marker's effectiveDate rather than the device's first sighting. suppressedUntil = min(effectiveDate, now)+8d means the '8d window' exists only for devices that sight within moments of the reset; a day-7 processor gets 1d (so a single SIGKILL before its queued re-push + a 1-day gap wipes its sole-copy data — row 23's '≥8d of push failure' precondition is simply false for it); a first sight at 8-21d — an offline vacation device, or sync disabled/re-enabled — gets ZERO window despite the marker being live and sighted, and its first pass reconciles against the post-wipe zone before its first push, contradicting row 11 outright; a merely 8-14d-fast clock hits the same zero-window while row 14 claims that range is protected. That is a concrete violation of the core safety property with realistic preconditions, hence breaks-safety and verdict has-holes. Second, B5 marks ids processed even when handleSyncReset no-ops on nil modelContext — background content-available launches run full syncs before .onAppear ever sets the context, permanently consuming the reset undelivered (breaks-liveness against the 7d delivery guarantee). Third, id-map pruning by local clock breaks B1/row-13/row-15's 'processed once, no clock dependence' claims under ≥14d constant slow clocks — squarely inside the spec's own child-rolls-clock-back threat model, failing toward clear-selections/disable-blocking (weakens; bounded, extreme preconditions, honestly graded). Three nits: same-device double-dispatch via the GC await between classify and mark (idempotent but contradicts 'exactly once'); row 15's 'no extended suppression' is wrong for future-dated markers (rolling skew+8d window, bounded); row 3's unconditional 'Converges' hides the chunk-partial-wipe no-sight case that A2.1 does not cover.
> 
> I did not re-report the accepted residuals (rows 14>14d-fast, 20, 22, 23, intentional-behaviour-changes) except where their stated preconditions are demonstrably wrong (rows 14 and 23, folded into finding 1). All three substantive findings share cheap fixes that preserve the design's shape: per-requestId first-sight suppression anchor, mark-only-if-dispatched, and prune-only-when-marker-absent.

### stateMachine-1 [breaks-safety] Suppression anchored to marker effectiveDate gives late-sighting and fast-clock devices ~zero protection — post-wipe reconciliation deletes their sole-copy data

**Violated:**

Core safety property (local BlockedProfiles/SavedLocation deleted, FamilyActivitySelection cleared, outside all three exceptions); row 11's stated outcome; row 14's stated ≤14d-fast precondition; row 23's stated '≥8 days of continuous push failure' precondition; row 9's '~8d' claim. Rows 11/9 are not in the accepted-residual list, and the accepted rows' preconditions are mis-stated, so this is reportable on both grounds.

**Interleaving:**

extendSuppression(basis=effectiveDate) yields suppressedUntil = effectiveDate+8d regardless of WHEN a device first sights the marker. (a) Day-7 processor: device D (2-device family; D pushed profile P at T-1h; origin O reset at T without pulling first — resetSync never pulls, so O never holds P) first syncs at T+7d. Boundary-inclusive .process: sight extends suppression only to T+8d; selections cleared; re-push queued on pushTask; SIGKILL after B5.3 (ids marked) but before the queued re-push executes — row 9's exact crash point. User reopens at T+8d+1h: pass sights marker (extension no-op, T+8d is past), classify .skipAlreadyProcessed, pullProfiles → gate passes (now ≥ suppressedUntil), P absent from wiped zone, syncVersion>0 ⇒ P deleted BEFORE pushLocalData runs at end of pass. Permanent loss, zero push failures needed — row 23's '≥8 days of continuous push failure' precondition is false here (the real requirement is effectiveDate+8d − firstSight, i.e. 1 day at day-7 sight, shrinking to 0). (b) First sight ≥8d: device X offline (or sync-disabled) since before the reset first syncs at T+10d. Marker live (age 10d ≤ 21d), sighted, classify .skipExpired — but min(T, now)+8d = T+8d < now, so the extension is a complete no-op and row 11's claim 'sighted ⇒ suppressed — protected while others converge' is false. Same pass: reconciliation runs on X's very first post-reset pull, before X's first push, deleting every syncVersion>0 profile/location no other device re-pushed (sole-copy = anything X pushed after O's last pull and before the wipe). Any copy that reappears later via another device's push is re-created with needsAppSelection=true / cleared selectedActivity — FamilyActivitySelection loss outside exceptions (a)/(b). (c) Clock 8–14d fast: at sight, now = T+k > T+8d ⇒ suppressedUntil already past ⇒ zero window, yet per B3 this device cannot GC the marker — row 14's stated boundary ('≤14d fast … sight ⇒ suppression still protects its data') is wrong; protection actually dies at >8d fast, not >14d. Note the perverse inversion: an UNDECODABLE marker (basis=now) grants a full 8d window while a decodable 8d-old one grants none.

**Verifier's suggested fix (historical; superseded by #267):**

Anchor the window at per-device first sight: persist firstSightedAt per requestId (insert-only map, same withLock/prune lifecycle as processedResetRequestIds) and extendSuppression(basis = min(firstSightedAt, now)) exactly once per marker per device, for any marker with age ≤ gcTTL. Boundedness is preserved (one extension per marker per device, ≤ firstSight+8d, firstSight ≤ GC horizon), the rev-3 loop stays dead (suppression never affects processing), and rows 9/11/14/23's stated preconditions become true: every device gets a genuine 8d convergence window from ITS first sighting.

### stateMachine-2 [breaks-liveness] B5 marks the reset processed even when the dispatch no-ops on nil modelContext — reset consumed without ever being applied

**Violated:**

Liveness guarantee 'delivery to every device syncing within 7d (absent >14d-fast clocks)'; row 11's 'Marker age ≤ 7d: processes once — 3+ device delivery (#202.1)'; B5's implicit assumption that step 2's synchronous part actually clears selections.

**Interleaving:**

handleSyncReset (SyncCoordinator.swift:529) begins `guard let context = modelContext else { return }` — a silent no-op. setModelContext is called only from WindowGroup .onAppear (FoqosApp.swift:227), but didReceiveRemoteNotification (FoqosApp.swift:341ff) drives handleRemoteNotification → performFullSync on content-available pushes that cold-launch the app in the BACKGROUND, where .onAppear never fires. Interleaving: parent resets at T with clear-selections; child's device is background-launched by the zone-change push at T+1h with modelContext == nil; pullResetRequests sights the marker (suppression extended — data safe), classifies .process, B5.2 dispatches didReceiveSyncReset which returns immediately (nil context: no selection clear, no re-push queued), B5.3 then unconditionally marks the requestId processed and persists it. Every subsequent foreground pass: .skipAlreadyProcessed. The clear-selections command is never applied on that device, permanently — no crash, no network failure, no clock skew required. The same one-shot race exists at foreground cold start if the notification Task's performFullSync wins the MainActor race against .onAppear.

**Verifier's suggested fix (historical; superseded by #267):**

In the B5 sequence, treat nil modelContext as 'not delivered': skip both the dispatch and the marking (and the retire-the-rest marking) for that pass, leaving the candidates .process-eligible for the next pass; equivalently have didReceiveSyncReset/handleSyncReset return a Bool 'applied' and only mark ids whose dispatch confirmed a context. Same guard applies to the pure marking helper's inputs so tests can pin it.

### stateMachine-3 [weakens] Local-clock pruning of processedResetRequestIds breaks process-once idempotency under a constant ≥14d-slow clock — expired reset re-clears selections

**Violated:**

B1's stated guarantee ('a request whose requestId is in the map is never processed again — no clock dependence'); rows 13/15 stated outcomes; the letter of safety exception (b) (selection-clearing applied for a reset >7d old in real time); constraint 'every clock-dependent rule must fail toward keep data / keep marker'.

**Interleaving:**

Prune-by-own-clock reintroduces the clock dependence B1 claims to have eliminated. Device clock constant s ≥ 14d slow (spec constraint: 'assume children roll clocks back'; a child sets the clock back once, before the reset): marker M saved at server time T (effectiveDate = creationDate = T). Device sights it at real T+ε; local now = T−s ⇒ M appears future ⇒ age clamps to 0 ⇒ .process ⇒ processed (legitimate), entry recorded at local T−s. 21 LOCAL days later (real T+21d) the prune fires: entry removed. Same or next pass, M is still fetchable (origin retired/dormant after the reset — a realistic 'reset then replace phone' flow; or another device's GC delete failed and retries lag; or stale query presence): classify with empty map — age = local now − T = 21d − s ≤ 7d ⇒ .process AGAIN ⇒ selections cleared for a reset that is 21+ real days old (outside safety exception (b)'s ≤7d), re-push, follow-up sync, id re-marked. For s > 21d this repeats every 21 local days until age exceeds 7d — bounded at ≈⌈(s−14d)/21d⌉+1 total applications, so the rev-3 INFINITE loop is genuinely dead (under any constant skew the count is finite; only unbounded repeated clock oscillation yields unbounded re-clears), but B1's 'no date arithmetic, no clock dependence, never processed again' and row 15's 'processed once (id-idempotent)' / row 13's 'no loop possible by construction' are overstated: the id map's PRUNE is date arithmetic on an untrusted clock, and it fails toward 'clear selections / disable blocking' — the wrong direction for a screen-time app per the spec's own fail-toward-keep rule.

**Verifier's suggested fix (historical; superseded by #267):**

Prune an id only when its marker is confirmed gone: remove an entry iff its requestId was NOT among the recordIDs returned by the current pullResetRequests fetch AND the entry is older than gcTTL (belt: keep the age floor as a growth bound). A live/fetched marker can then never lose its idempotency record, killing reprocessing under every clock configuration while keeping the map bounded (markers are GC'd at 21d, after which entries age out).

### stateMachine-4 [nit] GC-delete await sits between classification and mark in the data-flow diagram — concurrent passes can double-dispatch the same marker on one device

**Violated:**

B5's 'exactly once' wording / 'before any suspension point' as diagrammed (safe direction, so nit).

**Interleaving:**

The diagram orders 'classify all decoded; age>21d ⇒ GC-delete (failures ignored); newest .process ⇒ dispatch ⇒ mark'. GC-delete is a network await: pass 1 classifies M as .process (map read), suspends in a GC delete for some other expired marker; pass 2 (manual Sync Now) fetches, reads the still-unmarked map, classifies M .process, dispatches, marks; pass 1 resumes and dispatches M again. Double selection-clear + double re-push — idempotent and row-12-safe, but it contradicts B5's 'every device processes each reset exactly once' and the 'mark … before any suspension point' commitment is currently only stated relative to the dispatch, not relative to GC.

**Verifier's suggested fix (historical; superseded by #267):**

Pin in the spec and code-review checklist: read processed map → classify → dispatch → mark must be one synchronous MainActor slice immediately after the fetch resumes; perform GC deletes only after marking.

### stateMachine-5 [nit] Row 15's 'no extended suppression' is inaccurate: a future-dated marker re-extends suppression from `now` on every sighting

**Violated:**

Row 15's stated outcome ('normal 8d window. No loop, no extended suppression').

**Interleaving:**

Receiver s days slow: marker effectiveDate T appears future for s days; every pass in that span extends suppression to min(T, now)+8d = now+8d, a rolling window. Total suppression ≈ s+8d in the receiver's frame (it stops growing once local now passes T, or once other devices GC the marker), not the 'normal 8d window' row 15 claims. Bounded by skew, so the liveness bullet 'cannot be extended unboundedly by any single marker' technically survives, but only with a 'bounded by skew' caveat the spec doesn't state; deletion propagation on a badly slow device is delayed by skew+8d.

**Verifier's suggested fix (historical; superseded by #267):**

Either state the skew+8d bound honestly in row 15, or extend from a future-dated marker at most once per requestId (falls out of the per-requestId first-sight fix for the breaks-safety finding).

### stateMachine-6 [nit] Row 3's unconditional 'Converges' hides the chunk-partial-wipe + no-sight case (non-empty pull, A2.1 does not skip)

**Violated:**

Row 3's stated outcome (internal consistency with row 20; the accepted residual itself is not being re-reported).

**Interleaving:**

Origin crashes mid-type during the chunked wipe (e.g., 500 profiles, first 400-record chunk deleted). Row 3 claims non-sighting devices are safe because 'wiped types pull empty ⇒ A2.1 skips' — but a partially wiped type pulls NON-empty (the remaining 100), so on a device whose pullResetRequests was query-stale-absent for the (earlier-saved) marker, reconciliation runs against the partial set and deletes local copies of the wiped chunk. This is exactly row 20's accepted no-sight staleness class — not a new mechanism — but row 3 asserts convergence without the caveat, so the table overstates the wipe-partial guarantee.

**Verifier's suggested fix (historical; superseded by #267):**

Amend row 3: 'devices that don't sight it: fully-wiped types pull empty ⇒ A2.1 skips; a partially-wiped type is row 20's no-sight residual.'

## Lens: specReview — verdict: has-holes

**Verifier reasoning:**

> Read docs/superpowers/specs/2026-07-02-reset-sync-safety-design.md (REVISION 4) in full, 371 lines. Findings for each requested check, human meatbag:
> 
> **(1) Placeholders** — none found. Grepped for TODO/TBD/FIXME/XXX/[fill/placeholder/<INSERT/???; the only hit was "read-only placeholders" in row 22, which is a domain term (stale husk records) not a spec placeholder marker. No unfilled sections, no dangling brackets.
> 
> **(2) Internal contradictions — TTL arithmetic, checked in every row**
> `suppressionWindow = 8 days` ("processTTL + 1 day of slack", A1), `processTTL = 7 days` (B2), `gcTTL = 21 days` (B3), `margin = gcTTL − processTTL = 14 days` (B3). Every row that cites a duration uses these consistently: row 2 "≤ 8d", row 9/15 "~8d"/"8d window", row 11 "≤ 7d... 7–21d... >21d" (matches B4's exact ranges), row 14 "≤14d fast... >14d fast" plus the explicit correction note "arithmetic now consistent: margin = gcTTL − processTTL = 14d", row 23 "≥8 days of continuous push failure". The "Intentional behaviour changes" section ("~8 days", "up to ~21 days", "≤8 days across an account switch") and B4's boundary claims (7d ⇒ process-eligible, 21d ⇒ still `.skipExpired`, 21d+1s ⇒ `.expiredCollect`) all agree with the >, ≤ operator directions used consistently across B2/B3/B4/A2/test-plan item 1. No arithmetic contradiction found — this is the one area I expected to find slippage and didn't.
> 
> **(2) Other contradictions/gaps vs mechanisms, diagram, test plan** — see `breaks` list below (items 1, 2, 6).
> 
> **(3) Ambiguity**
> - `extendSuppression` basis per caller: origin (`resetSync`, Part C step 2) uses `extendSuppression(now)` explicitly. `pullResetRequests` uses "marker's effective date, or `now` when unknown" — decoded records use `effectiveDate` (B2), undecodable/failed-fetch records use `now`. These two callers are consistent with each other and with the data-flow diagram's `extendSuppression(effectiveDate | now)`. No third caller exists (B5 step 1 reuses the same "on sight" A1 trigger, not a new call site).
> - Shared suppression key: `SharedData.syncDeletionSuppressedUntil` is declared once (A1) and reused verbatim by both `handleSyncedProfiles` and `handleSyncedLocations` (A2, confirmed by the data-flow diagram's "same, minus the schema clause" for locations, and by the interleaving tables treating both under one combined section, rows 18–23). No row assumes a per-type or per-record-type suppression clock — this is confirmed consistent.
> - Two real ambiguities found and reported below: (a) tie-breaking for "the newest" `.process` candidate when two markers share an `effectiveDate` (B5) is unspecified; (b) whether the classify→dispatch→mark sequence in B5 is safe under the doc's own "Concurrent passes exist... can overlap at await points" constraint is asserted (row 12: "No race") but not walked through for the same-device concurrent-pass case, only the cross-device case.
> 
> **(4) Test-plan completeness vs claimed fixes and code-inspection commitments**
> Mapped every #195/#202 sub-item and every "Intentional behaviour changes" bullet to either a pure unit test (1–7) or a code-inspection commitment (4 bullets). Two gaps found and reported below: the ordering guarantee that actually closes #195.4 (intra-pass race) is never listed in the commitments (only the *failure*-abort path is), and the "Account switching" behavioral claims have no test or commitment at all. A smaller nit: A2's `now ≥ suppressedUntil` boundary isn't given the same exact-equality boundary test that B4's 7d/21d boundaries get.
> 
> Overall the core safety mechanism (monotonic max, TTL arithmetic, single shared suppression key, upserts-always/deletes-gated split) is internally consistent and the numbers check out everywhere I looked. The holes are all in verification-coverage/specification completeness (missing commitments, one unanalyzed interleaving, one unresolved tie-break), not in the core arithmetic or the profiles/locations shared-key design.

### specReview-1 [weakens] The invariant that actually closes #195.4 (intra-pass re-push race) is never listed in the code-inspection commitments

**Violated:**

The 'Code-inspection commitments' list only has 4 bullets: resetSync step order (C.1-4); 'suppression extended on raw recordID sight before decode/classify (B/A1), and didReceiveSyncReset dispatched before ids are marked (B5 order)'; chunking/wipe-exclusion/GC-failure handling; and 'pass-abort: pullResetRequests failure prevents all reconciling pulls (Part C)' -- which only covers the *failure* case. None of the four bullets states the success-path sequencing fact ('pullResetRequests fully completes, including its suppression write, before pullProfiles runs, within one pass') even though that is the load-bearing mechanism the design credits with closing a *critical* bug's sub-case.

**Interleaving:**

Row 19 credits closing #195.4 to suppression being extended by pullResetRequests before the same pass's pullProfiles reconciles: 'remoteIds non-empty, suppressed | Skip. Closes #195.4 and every mid-window partial-zone case for devices that ever sighted the marker (or originated the reset).' That requires pullResetRequests's synchronous SharedData write to be committed and visible before pullProfiles runs later in the same performFullSync pass (success path, not just the abort-on-failure path).

**Verifier's suggested fix (historical; superseded by #267):**

Add a fifth code-inspection commitment: 'pullResetRequests's suppression-extension writes are synchronously committed before performFullSync proceeds to pullProfiles/pullLocations within the same pass (success path) -- this is the mechanism that closes #195.4.'

### specReview-2 [weakens] B5's classify-then-dispatch-then-mark sequence is a check-then-act pattern across an await point, but the doc only analyzes the cross-device case, not the same-device concurrent-pass case its own constraints section calls out

**Violated:**

No interleaving row models: 'same device, two concurrent performFullSync passes, both classify the same requestId as .process before either reaches step 3' -- despite the constraints section explicitly flagging that overlap as real ('can overlap at await points'). The Concurrency & storage discipline section only commits `withLock` around the *individual* extendSuppression and processed-id insert/prune operations, not around the classify->dispatch->mark sequence as a unit, so double-dispatch of didReceiveSyncReset (double selection-clear, double re-push) before either pass marks the id processed is not ruled out by anything stated.

**Interleaving:**

The constraints section states: 'Concurrent passes exist. performFullSync has no reentrancy guard; manual "Sync Now", remote notifications, setup, and the reset follow-up can overlap at await points. Any new state must be safe when read/written by interleaved passes.' B5's own ordering is: '1. suppression already extended... 2. dispatch didReceiveSyncReset(...)... it then chains re-push -> follow-up performFullSync on the pushTask chain; 3. mark requestIds processed (synchronously, same iteration, before any suspension point).' Between step 1 (classify sees the id as unprocessed) and step 3 (mark processed) there is an await (dispatch chains async work) on this device's own concurrent second pass. Row 12 only says: 'Two receivers process the same marker concurrently | Both apply (idempotent); ids marked on each; marker not deleted. No race' -- which reads as two *different devices*, each with its own independent processedResetRequestIds map, not two concurrent passes racing on the *same* device's single map before either writes 'processed'.

**Verifier's suggested fix (historical; superseded by #267):**

Add an explicit interleaving row for 'same-device concurrent passes both see requestId as unprocessed before either marks it' and state why double-dispatch of didReceiveSyncReset is safe (e.g., because clearing selections and re-pushing are themselves idempotent) -- or add a lock/guard and say so.

### specReview-3 [nit] B5's tie-break rule for 'the newest' .process candidate is unspecified when two markers share the same effectiveDate

**Violated:**

'B5. Process the newest, once; retire the rest. Per pass: among .process candidates, dispatch only the newest (by effectiveDate)' presupposes a unique maximum but never states a tie-break. Test-plan item 2 ('several .process candidates => exactly the newest dispatched') also doesn't cover a tie.

**Interleaving:**

Row 6 ('Two devices reset near-simultaneously') is exactly the scenario where two SyncResetRequest records could have equal or sub-second-indistinguishable effectiveDate (CKRecord.creationDate) or, on the requestedAt fallback, an identical client timestamp.

**Verifier's suggested fix (historical; superseded by #267):**

State an explicit deterministic tie-break (e.g., requestId lexicographic order) so two devices computing 'the newest' independently are guaranteed to agree, and add a boundary test for it.

### specReview-4 [weakens] The 'Account switching' behavioral claims have no test-plan item or code-inspection commitment

**Violated:**

Intentional behaviour changes states: 'Account switching: processedResetRequestIds are UUIDs (cannot collide across accounts -- no cross-account suppression of delivery); syncDeletionSuppressedUntil may carry <=8 days across an account switch (blocks only deletions -- safe direction). Neither needs account-scoping.' Neither the 7-item pure test list nor the 4-item code-inspection commitments list mentions 'account' anywhere -- every other claimed behavior change in the doc maps to at least one of those two lists; this one maps to neither.

**Interleaving:**

An account switch on a device that has an active syncDeletionSuppressedUntil or processedResetRequestIds state from the prior account.

**Verifier's suggested fix (historical; superseded by #267):**

Add either a unit test (processedResetRequestIds UUID non-collision reasoning doesn't need CK, so is arguably pure-testable as 'no special-casing needed') or, at minimum, a fifth code-inspection commitment calling out that no account-scoping code was added and why that's safe, so a reviewer actually checks it.

### specReview-5 [nit] A2's suppression boundary (now == suppressedUntil) lacks the exact-equality boundary test the doc gives every other TTL boundary

**Violated:**

A2 states the operator precisely: 'now >= syncDeletionSuppressedUntil (read fresh from SharedData inside the reconciliation branch; nil passes)' -- i.e. reconciliation is allowed to run exactly at the boundary. Test-plan item 4 only lists 'non-empty remote, suppression expired (or nil), one missing => deleted' without pinning now == suppressedUntil, unlike test-plan item 1's meticulous 7d/21d/21d+1s boundary pins for classify.

**Interleaving:**

A device's clock reads exactly syncDeletionSuppressedUntil at the moment handleSyncedProfiles runs.

**Verifier's suggested fix (historical; superseded by #267):**

Add a boundary case to test 4: now == suppressedUntil exactly => reconciliation runs (matches the >= operator).

### specReview-6 [nit] The data-flow diagram places GC-delete between suppression-extend and dispatch/mark, but B5's prose 'single most correctness-critical sequence' only enumerates 3 steps and never places GC in it

**Violated:**

B5 says: 'Ordering inside the pass, single most correctness-critical sequence: 1. suppression already extended...; 2. dispatch didReceiveSyncReset...; 3. mark requestIds processed...' -- three steps, framed as *the* critical sequence. The data-flow diagram shows a fourth phase interposed: 'classify all decoded; age>21d => GC-delete (failures ignored)' sitting between the suppression-extend line and the 'newest .process => didReceiveSyncReset -> mark ALL .process ids processed' line. Functionally harmless here since .process (age<=7d) and .expiredCollect (age>21d) sets are disjoint, but the prose's claim to completeness ('single most correctness-critical sequence') is contradicted by the diagram depicting an unlisted step.

**Interleaving:**

A single performFullSync pass where pullResetRequests fetches both an expired (>21d) marker and a live (.process) marker in the same batch.

**Verifier's suggested fix (historical; superseded by #267):**

Either fold GC-delete explicitly into the B5 ordering list (even just to state 'GC-delete may happen before or after step 2/3, order is immaterial because .process and .expiredCollect are disjoint by age'), or note in the diagram that GC ordering is intentionally unconstrained.
