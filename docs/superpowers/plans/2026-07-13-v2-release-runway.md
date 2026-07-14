# V2 Release Runway — from here to "V2 live on the App Store"

**Date:** 2026-07-13 · **Grounded at:** `origin/main` @ `84f460a`, `origin/release/v1` @ `589bee9` (= tag `v1.31.3`), live GitHub state, current Apple documentation.
**Scope:** everything standing between the current state of the repo and V2 live on the App Store. Epic #263 completion gates the release (maintainer decision, `docs/audits/v1-v2-family-upgrade-audit.md:250`); V1 is live with real users and V1-user data loss is release-blocking.
**Method:** 8-cluster multi-agent research pass + adversarial verification of every release-gating claim (15/16 confirmed, 1 refuted and corrected). No claim below is inherited from an issue/PR body without an independent check.

---

## 0. Corrections — stale claims found during grounding

Per the standing rule (the debunked "Family Controls distribution entitlement needs weeks of Apple lead time" precedent), these claims in the backlog are **wrong or stale** and should not steer planning. None are fixed by this PR (docs-only); each is a one-line edit for the maintainer or a future session.

| # | Where | Stale claim | Ground truth |
|---|-------|-------------|--------------|
| C1 | Issue #326 body | "TestFlight later requires the Family Controls distribution entitlement (request from Apple immediately — weeks-long lead, required for the App Store regardless)" | **False.** All four V2 `.entitlements` files are byte-identical to live V1's (`Foqos/foqos.entitlements:11`, `FoqosDeviceMonitor/FoqosDeviceMonitor.entitlements:5`; `git show origin/release/v1:<same>` identical). The grant sits on the App ID and persists across updates of the same bundle IDs ([Apple: requesting the Family Controls entitlement](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement)). V1 being live *is* the proof the grant exists. There is nothing to request and no lead time. Epic #263 was corrected 2026-07-13; #326 was not. |
| C2 | Issue #326 body vs epic #263 | #326: "dev-install works now (no TestFlight needed)" | Contradicts the later ruling in epic #263 (2026-07-13): "no dev-install — the only spare iPhone is an SE too old to upgrade; TestFlight to his device when the app is more complete." The epic note is newer and authoritative; #326 needs reconciling (Appendix B, MD-1). |
| C3 | Epic #263 body, W3-B block | `[ ] #311 · [ ] #305 · [ ] #315 · [ ] #329` | All four are **CLOSED**, merged by PR #334 (2026-07-13, `c033ac4`, `closingIssuesReferences: [305,311,315,329]`). Boxes are stale; only device rows remain (Appendix A). |
| C4 | Issue #310 body + epic #263 Wave-4 line / dependency note 3 | "needs a plan (blocked on #307 diagnosis)" | #307 is fully **fixed** (not just diagnosed) — PR #341 merged 2026-07-13T21:28Z. The plan exists: PR #343 (open, reviewer-approved). #310/#328 are unblocked. |
| C5 | Maintainer-decision folklore | "File the Family Controls distribution request now" as an open action | Not a real action — see C1. Removed from the open-decisions register (Appendix B). |
| C6 | This session's own scout premise | "release/v1 has unreleased commits after v1.31.3 (#49/#50)" | **False.** The annotated tag `v1.31.3` (2026-02-12) points at `589bee9` = the branch tip. `git log v1.31.3..origin/release/v1` is empty; PRs #46/#49/#50 are all *inside* the tag. Nothing is pending or stranded on `release/v1`; no open PRs target it; no milestones exist. |
| C7 | `docs/audits/v1-v2-family-upgrade-audit.md` internals | Issue-6 "counter carries over on upgrade"; issue-4 "build a min-version mechanism"; B1 "offline = no PIN" | Already self-corrected at `audit.md:244-249` and in #332/#330 — listed here so nobody re-inherits the uncorrected lines at `audit.md:126-136/:154/:60`. |

---

## 1. Where we are

- **Shipped V1:** `v1.31.3` (tag == `release/v1` tip == live version per the 2026-07-12 App Store Connect analytics check on epic #263 — all opted-in active users bridge-equipped, no pre-bridge holdouts). The bridge (schema awareness, V2-read-only, push-skip) is confirmed in shipped code (`release/v1:BlockedProfiles.swift:42,64-66`, `SyncCoordinator.swift:481`). **No V1 work is pending anywhere.**
- **V2 (`main`):** version already set to `2.0.0` / build 19 uniformly; Swift 6; deployment target 18.6 (unchanged from V1); `ITSAppUsesNonExemptEncryption = NO` as a build setting (`project.pbxproj:870,924`) so no per-build export prompt.
- **2026-02 migration success criteria** (`docs/plans/completed/2026-02-06-v1-v2-migration-success-criteria.md`): **essentially fully met in code** — one-way/atomic/idempotent/deferred migration (`BlockedProfiles.swift:796-845`, `ProfileMigrationUtil.swift`), V2-authoritative sync with conflict banner + auto-heal (`SyncApplyService.swift:325-338`), all 8 strategy mappings (`TriggerMigration.swift:14-53`), bridge behaviors. Residuals: (a) bridge banner copy diverges from spec ("Update app to edit" vs "Update Foqos to edit this profile") — cosmetic, unowned, not gating; (b) "blocking still works on bridge for V2 profiles" is code-plausible but not device-proven — added to Appendix A as a probe; (c) backwards-compat strategyId intentionally removed (#39/#61), de-risked by the adoption check. The genuine migration-area blocker is #328, already owned.
- **Remaining engineering** is concentrated in three bundles (R1–R3 below) plus hygiene (R4) and the closing sweep (R5). Two release blockers exist **outside** the epic with no issue until now (R6 = #345, R7 = #346, filed with this runway).

---

## 2. The runway (ordered)

Gate ratings: **BLOCKING** = V2 cannot ship (or cannot upload/pass review) without it; **SHOULD** = ship-without is possible but wrong; **NICE** = quality. Every open epic-#263 item is formally BLOCKING via the "#263 completes first" rule; the rating below is *intrinsic* impact, with the epic gate noted. Owner: **A** = agent-doable, **M** = maintainer-only, **A+M** = split.

### Stage 1 — finish the engineering (epic #263; strictly sequential, one bundle at a time)

**R1 · Tail bundle — merge `fix/263-tail-bundle`** (#252 #247 #250 #238 #249 #331 #253 #254 #240) — **BLOCKING** (epic gate; #331 is the audit's "fix before release" dashboard-honesty item, scenarios B3/B4)
All 9 issues OPEN. The code is **written**: 13 commits on the local, unpushed branch `fix/263-tail-bundle` (f708577 → 0ef33ff), covering every issue; verified absent from `origin/main` (all 13 fail `merge-base --is-ancestor`). No PR exists. Remaining work: device gates (H2-3 #247 child-mode redaction, H3 #250 export archive, G1 #238 widget timeline, G2 #249 Live Activity switch — plan `docs/superpowers/plans/2026-07-10-263-tail-logging-widgets-readme.md:375,701,1077,1516`), push, review, merge. The plan's two MDs (H2, J1a-1) and #331's confirm-vs-copy fork are **de-facto ruled by the commits** (74b8b0f = redact-A with QR-digest refinement; d483871 = honest placeholders; 254e319 = confirmation path) — reviewers ratify them at PR time rather than re-litigating. Deps: none (in flight now). Owner: **A** (push/PR/review) + **M** (device gates, merge). *Note: #331's device gate needs a V1-child + V2-parent pair — it lands in Appendix A, not on the merge path.*

**R2 · #316 + #335 — implement the approved sync-status/triggers plan** — intrinsically **SHOULD**, BLOCKING via epic
Plan PR #342 merged (plan-only), all three MDs ruled in the PR review comments (MD-1 = recommendation, MD-2 = A event-driven capped backoff, MD-3 = A full syncNow on reconnect). Implementation not started; sequenced behind R1 per the plan. Fixes the dead `isSyncing`/`lastSyncDate` status and the 26-minute re-add stall. Deps: R1 merged (sequential rule). Owner: **A**; DV-1/DV-2 device rows → Appendix A.

**R3 · #310 + #328 — implement the establishment-generation wipe** — **BLOCKING** (audit finding 1, "RELEASE-BLOCKING high", `audit.md:90-100`; the only OPEN high-severity item with no accepted-risk waiver)
Plan PR #343 open and reviewer-approved; MD1 (surfaced one-time notice) and MD2 (adopt-and-discard) ruled in PR review comments — ruled-but-overridable until the PR merges. #307, the former hard blocker, is fixed (PR #341). This bundle is what makes "Totally delete all synced data" stick (#310) and gives Reset Sync convergence against a live V1 peer (#328 — generation-less V1 records = dead world → discard). It is also the **last schema-touching bundle**, which pins R7's timing. Deps: R2 merged (sequential rule). Owner: **A**; 6-row DV matrix → Appendix A.

**R4 · J2 hygiene sweep** (#319 #293 #255 #256 #257 #259 #248; #258 resolves via R9/#320, do **not** delete FoqosUITests) — intrinsically **NICE**, BLOCKING via epic
Dead-code/warnings cleanup; must run **last** among code bundles (deletes what everything else touches; epic dependency note 4). Deps: R1–R3 merged. Owner: **A**.

**R5 · Wave-6 closing sweep** — **BLOCKING** (epic)
Four legs per the epic: multi-agent fix-composition re-audit; device-behavioral pass; re-read of accumulated logs/captures; family-mode device pass (= #326, which is R8's payload). Deps: R1–R4. Owner: **A** (re-audit, log re-read) + **M** (device legs).

### Stage 2 — the two blockers nobody had filed (filed with this PR)

**R6 · Author privacy manifests (4 × `PrivacyInfo.xcprivacy`)** — **BLOCKING for any upload, including TestFlight** — *filed as #345*
No `PrivacyInfo.xcprivacy` exists on `main` or `release/v1` (`git ls-tree -r --name-only … | grep -i privacy` → empty on both). UserDefaults — a required-reason API, category `NSPrivacyAccessedAPICategoryUserDefaults` — is used in **all four binaries** (app; `FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift`; `FoqosShieldConfig/ShieldConfigurationExtension.swift`; `FoqosWidget/FoqosWidgetBundle.swift`). Since 2024-05-01 App Store Connect **rejects uploads** that use required-reason APIs without a manifest declaration (ITMS-91053), and each bundle needs its own manifest — the app's does not cover extensions ([Apple: describing use of required-reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)). Good news: UserDefaults is the *only* triggered category (file-timestamp/uptime/boot-time/disk-space APIs: zero hits), so this is four small files declaring `CA92.1`/`1C8F.1` (app-group access). V1 predates enforcement; V2's upload hits it head-on. Deps: none — can land any time before the first upload. Owner: **A**.

**R7 · Deploy the V2 CloudKit schema to Production (+ refresh the stale `.ckdb`)** — **BLOCKING for TestFlight and the App Store** — *filed as #346*
V2 adds **5 record types** absent from V1 (`DeviceHeartbeat`, `FamilyCommand`, `EmergencySettings`, `EmergencyResetEpoch`, `EmergencyUnblockEvent` — `SyncModels.swift:483/578/621`, `FamilyCommand.swift:43`, `DeviceHeartbeat.swift:17`) plus ~10 new `SyncedProfile` fields (trigger/schedule/NFC/QR, `SyncModels.swift:52-78`), split across the private-DB `DeviceSync` zone and shared-DB `FamilyPolicies` zone of the one production container `iCloud.com.cynexia.family-foqos` — the same container live V1 users are in. CloudKit **Production does not auto-infer schema**, and **TestFlight builds run against Production** ([Apple: deploying an iCloud container's schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)) — so without a console deploy, sync silently fails for every tester and every released user. Nothing in the repo or docs mentions deployment, and the in-repo export `Foqos/CloudKit/cloudkit-schema.ckdb` is **stale** (missing 4 of the 5 new types; last touched at `2e38ca5`; drift already flagged at `docs/plans/2026-07-02-sync-engine-design.md:775`). Timing: production schema is additive-only once deployed — deploy **once, after R3** (the last schema-changing bundle) and before the first TestFlight build. Owner: **M** (CloudKit Console) + **A** (ckdb refresh, runbook note). Caveat: if #310's implementation adds a record type/field beyond today's set, the deploy must include it — hence "after R3".

### Stage 3 — release-readiness engineering (epic tier)

**R8 · #321 — CI version-increment merge gate** — **SHOULD**
The repo's genuinely-first workflow (`.github/` does not exist). Version is already monotonic-ready (2.0.0/19 > 1.31.3/4). Two parts: the Actions workflow (**A**) and making it a required status check in repo settings (**M**, UI-only). Optional rider (maintainer's call per issue): run `scripts/check-sync-guards.sh` + `check-c2-guards.sh` + unit suite on PRs. Deps: none; any time. Not on the TestFlight critical path.

**R9 · #320 — fastlane snapshot screenshots** — **SHOULD** (App Store listing quality; also resolves #258 by repurposing, not deleting, the empty FoqosUITests target)
An *update* submission can technically reuse the existing V1 screenshots, but V2's UI diverged enough that shipping them would misrepresent the product — treat as required-in-practice at submission, not for TestFlight. Caveat from the issue: FamilyControls surfaces (shields, pickers) may not render in simulator → split device-only vs simulator shots. Deps: near-final UI (post-R4 sensible). Owner: **A** (harness + sim shots) + **M** (device-only shots, listing upload).

### Stage 4 — TestFlight (unlocks the biggest deferred-verification block)

**R10 · Upload build → TestFlight → son's device → run #326** — **BLOCKING** (Wave-6 family leg; carries the largest device-debt class in Appendix A)
Prereqs: R6 (upload passes), R7 (sync works in prod), an Xcode 26 archive (**M** — signing is biometric-gated, agents cannot do this), and the "app more complete" bar the maintainer set — which this runway reads as *post-R3*, since the family pass exercises #247/#331 (R1) and the mixed-version scenarios (R3). Apple mechanics, verified: the current SDK floor is Xcode 26 / iOS 26 SDK (required since 2026-04-28) — **no need to wait for Xcode 27** (#322 agrees: "no submission pressure", GM cutover ~Sept is a toolchain choice, not a gate); Family Controls works in TestFlight (distribution profile, same as App Store); TestFlight minimum age is 13 (US/UK; 16 in DE/AT/ES) so the son (15) clears the numeric bar, **but** accounts flagged "Child" in Family Sharing have documented friction as external testers — if his Apple ID is teen-classified this is fine; if child-classified, plan the fallback in #326. External testers need Beta App Review on the first build (~1-2 days); internal testers (ASC team members) skip it. His **consent** is required (child-mode auth is real screen-time authority; the #232 row revokes permissions on his device). Owner: **M** (+son).

### Stage 5 — submission mechanics (all maintainer-only, mostly at-submission)

**R11 · App Store Connect privacy nutrition label update** — **BLOCKING at submission** (no code)
V2's new data flows (CloudKit family sync of profiles/sessions/commands/heartbeats across accounts) almost certainly expand the current label (likely User Content / Identifiers linked to the account). Edited in ASC with the version; required to submit updates ([Apple: app privacy details](https://developer.apple.com/app-store/app-privacy-details/)). Owner: **M**.

**R12 · Release notes** — **BLOCKING at submission** (assembly unowned until now — tracked in Appendix B, MD-4)
Must include, verbatim commitments already made: the #332 note — *"emergency unblock limits are per-device until all your devices update"* (`audit.md:160`; #332 closes when it ships) — and consistency with #310's wipe-confirmation V1 caveat (the in-app string ships with R3). **A** can draft; **M** signs off.

**R13 · Pre-submission re-check of bridge saturation (audit probe P2)** — **SHOULD**
The 2026-07-12 check found all opted-in users on v1.31.3; re-confirm at submission time (cheap ASC analytics look) since weeks will have passed. If pre-bridge (≤v1.31.1) holdouts appear, a min-version gate must ship first (`audit.md:136,180,244`). Owner: **M**.

**R14 · Phased release vs immediate** — decision, **BLOCKING at submission** (Appendix B, MD-3)
Real tension, not a formality: phased (7-day) limits the blast radius of V2 defects on the live user base, but **prolongs the mixed V1/V2 window** that #328/#329/#331/#332 exist to survive — and phased throttles only auto-updates (manual updates and new downloads always get V2 immediately, [Apple: phased release](https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases/)), so the mixed window exists either way. With the R3 mitigations merged, this runway mildly favors **phased with active monitoring** (pause is available up to 30 days); the audit leaned the same way (`audit.md:136`). Maintainer's call.

**R15 · Submit → App Review** — **M**
Review posture verified favorable: Screen Time API / Family Controls is Apple's sanctioned path for parental-control apps; relevant rules (5.1.2 data use, Kids-category rules) pose no evident issue for V2's parent/child model. No action beyond honest metadata.

### Stage 6 — post-release

**R16 · V1 sunset** — **NICE** (sequencing decision in Appendix B, MD-2)
`release/v1` is already quiescent (tip == v1.31.3 == live; zero open PRs/milestones; the four open V1-tagged issues need no V1 build). Close #330 when V2 adoption makes the fail-open window negligible; #332 closes when the note ships; #59 dissolves at sunset. Owner: **M**.

---

## 3. Shortest critical path to TestFlight-on-son's-device

The single sequence that unlocks the largest block of deferred verification (the whole `[testflight-son]` class plus the family legs of Wave 6):

```
R1 tail bundle merge  ──►  R2 #316/#335 impl  ──►  R3 #310/#328 impl ──►  R7 prod-schema deploy (M, ~1h console)
      (in flight)            (plan approved)         (plan approved)   ┌──────────┘
R6 privacy manifests ──────────────────────────────────────────────►  archive + upload w/ Xcode 26 (M)
      (any time, small PR)                                             └►  ASC: invite son (consent + teen-account check;
                                                                            Beta App Review ~1-2 days if external tester)
                                                                                └►  #326 family pass (Appendix A batches)
```

- **Agent-side length:** three sequential implementation bundles (R1 is already written — its remaining agent work is push/PR/review-fixes) + one small manifests PR that can land in parallel with any of them.
- **Maintainer-side length:** device gates for R1, ~1 hour of CloudKit Console (R7), one archive/upload, one tester invite, the consent conversation.
- **Deliberately off this path:** J2 (R4), CI gate (R8), screenshots (R9), all Stage-5 mechanics — none of them block a TestFlight build.
- **Could TestFlight happen even sooner** (before R2/R3)? Mechanically yes — R6 + R7(current schema) + upload. But it wastes the pass: the family rows need R1's #247/#331 and R3's mixed-version fixes, and R7 would have to be deployed twice. Not recommended; noted because the "app more complete" bar is the maintainer's to set.

---

## Appendix A — Consolidated device-debt register

Every deferred/future device-verification row across PR bodies #333/#334/#341 (+ earlier where still open), issues #326/#307-Step-7/#329, and the three in-flight plans (tail bundle #309, #316/#335 #342, #310/#328 #343). The tail-bundle PR does not exist yet; its rows are FUTURE until R1 opens it. **DEFERRED** = code merged, row unrun · **FUTURE** = code not yet merged.

### Batch 1 — `[second-icloud]` needs a second real Apple ID (+ a third device or re-sign to observe)
| Row | Source | Status | Step (condensed) |
|---|---|---|---|
| A1 | #307 Step 7 · PR #341 | DEFERRED | Device B signs into a *different* iCloud account → engine torn down pre-dialog; exercise all three choices (Combine ⇒ union propagates incl. forced-seed; Switch ⇒ local+emergency budget gone; Not-now ⇒ sync off, re-prompt available). Plan `2026-07-13-307-account-change-restart-fix.md:803`. |

### Batch 2 — `[second-device]` two same-user V2 devices
| Row | Source | Status | Step |
|---|---|---|---|
| A2 | #316/#335 DV-1 (plan :714) | FUTURE (R2) | Airplane-mode edit → reconnect → auto re-drive within seconds, no manual Sync Now; B receives. |
| A3 | #316/#335 DV-2 (plan :715) | FUTURE (R2) | Forced `serverRecordChanged` conflict → queue-drain re-send within backoff (≤~64 s, not 26 min). |
| A4 | #310/#328 DV-2 (plan :776) | FUTURE (R3) | Wipe on A → B adopts generation, discards, shows MD1 notice, no re-seed; both converge empty. |
| A5 | #310/#328 DV-3 (plan :777) | FUTURE (R3) | B offline during A's wipe → B's queued pre-wipe edits don't resurrect; adopt+wipe on first fetch. |
| A6 | #310/#328 DV-6 (plan :780) | FUTURE (R3) | Wipe during B's mid-fetch race → no husk resurrection either side. |

### Batch 3 — `[mixed-V1V2]` one device on App-Store v1.31.3 + one V2 device, same account
*(Runnable with the maintainer's own two devices — keep one on the store build. Not TestFlight-gated.)*
| Row | Source | Status | Step |
|---|---|---|---|
| A7 | #329 · PR #334 row A | DEFERRED | V2 device receives fetched delete, V1 re-pushes same version → no re-materialize (watermark holds). |
| A8 | #329 · PR #334 row B | DEFERRED | Higher-version recreation after fetched delete → DOES apply (`<=` gate). |
| A9 | #328 reset pair · #326 | FUTURE (R3) | Reset Sync from each side of a V1+V2 pair → behavior matches shipped mitigation. |
| A10 | #310/#328 DV-5 (plan :779) | FUTURE (R3) | Wipe on V2 with live V1 peer → V2 stays empty while V1 re-pushes (honest residual); then upgrade V1→V2 → adopt-and-discard (MD2). Explicitly "the #326 probe pair". |
| A11 | #331 · tail plan :378-386 | FUTURE (R1) | V1-child + V2-parent: dashboard shows honest empty copy; resets show "Sent — waiting for child to confirm", never fake success. |
| A12 | Bridge block-path probe (§5 criteria, this doc) | **UNOWNED — add to #326** | On the V1 device: confirm blocking still starts/stops on a V2-authored profile (read-only gate covers edit/push only; block path has no schema guard — code-plausible, never device-proven). |

### Batch 4 — `[testflight-son]` real child device (TestFlight per epic ruling; consent required)
| Row | Source | Status | Step |
|---|---|---|---|
| A13 | #230 · PR #325 | DEFERRED | Parent reset commands process on child *without relaunch* (PIN dialog, emergency screen, foreground polling). |
| A14 | #232 · PR #325 | DEFERRED | Revoked-permissions child → exactly ONE parent notification across heartbeats. ⚠ revokes permissions on his device — consent. |
| A15 | #241 · PR #325 | DEFERRED | Unresolved `userRecordID` family member survives participant sync (keep-don't-delete). |
| A16 | #221 · PR #306 | DEFERRED — **⚠ not enumerated in #326's inherited list; add it** | Reset emergency allowance on one device of the parent/child topology. |
| A17 | #247 · tail plan :76-78 | FUTURE (R1) | Child-mode Debug Mode masks NFC UID (`•••• (hidden in Child mode)`) in both entry points + copied markdown; parent/individual shows raw. |
| A18 | #326 general family pass | FUTURE | End-to-end: B1 lock-code sync/gating, D2 remote sessions on child, two-owner lock-code probe (P1) + cheap all-zones hardening decision, P3 (V1 leave-family no-PIN sanity), P4 (optional V2-child CKShare permission). |
| A19 | B2/#230/#232 unit-coverage note | — | Correction from adversarial verify: all five B2 rows (#230/#232/#241/#231/#208) **are unit-covered** (`FamilyCommandApplyTests`, `MonitoredDeviceTests`, `ParticipantRemovalDecisionTests`, `RequestAuthorizerTests`, `LockCodeChangedPinRegressionTests`); what's deferred is live acceptance only. |

### Batch 5 — `[visual / single-device]`
| Row | Source | Status | Step |
|---|---|---|---|
| A20 | #227 · PR #333 | DEFERRED | Real notification scheduling/cancellation (stable IDs, targeted cancel). |
| A21 | #245 · PR #333 | DEFERRED | DeviceActivity start/stop cleanup on deleted profiles (incl. Greptile's C2-backstop residual). |
| A22 | #224 · PR #318 | DEFERRED | Hold-to-start + in-flight geofence check → no duplicate session. |
| A23 | §D probe · PR #314 | DEFERRED | Empty-app-selection probe (gate stays regardless of outcome). |
| A24 | #298 · PR #339 | DEFERRED | Twin-view crash cycles + edit-propagation spot-checks (snapshot pattern). |
| A25 | #340 | DEFERRED | Location-picker empty state + edit-form scroll retention visual pass. |
| A26 | #238 · tail plan :1077 | FUTURE (R1) | Widget flips at schedule STOP/START edges with app force-quit. |
| A27 | #249 · tail plan :1516 | FUTURE (R1) | Live Activity shows switched-in profile's name; disabled-LA profile ends the banner. |
| A28 | #250 · tail plan :701 | FUTURE (R1) | Export Logs archive contains `foqos-app.log` + `foqos-monitor.log` (+widget), no collisions. |

### Batch 6 — `[reinstall / upgrade]` single device, special install
| Row | Source | Status | Step |
|---|---|---|---|
| A29 | #266 · PR #333 | DEFERRED | Install V1 → migrate to V2 → extensions read refreshed app-group snapshot. |
| A30 | #310/#328 DV-1 (plan :775) | FUTURE (R3) | Total wipe → reinstall → world stays empty (wipe sticks through reinstall). |
| A31 | #310/#328 DV-4 (plan :778) | FUTURE (R3) | Exhaust emergency ledger → wipe → reinstall → ledger cleared (the motivating 2026-07-11 case). |

### Batch 7 — `[assumption-probes]` load-bearing assumptions from the 2026-07-13 fix-composition sweep (verify before/at the R5 device leg)
| Row | Assumption (a clean verdict rests on it) | Probe |
|---|---|---|
| A32 | CKSyncEngine account-change event delivery/ordering on a real switch (`.signIn` echo timing vs `.switchAccounts`/`.signOut`) | Observe the permanent transition log during the A1 second-account run |
| A33 | CloudKit server semantics: redelivery after change-token reuse on switch-back; stale ≤-version re-publish (mixed-V1, #329); shared-zone membership across an account switch (heartbeats, lock-code fetches) | Fold into Batch 1/3 runs |
| A34 | DeviceActivity runtime: `intervalDidEnd` redelivery, wrap-anchor backstops, and whether accumulated backstops can approach the ~20-activity registration limit | Count registered activities on a long-lived device profile set |
| A35 | SwiftData pending-delete fetch exclusion (`context.delete()` before save excludes from fetches) — load-bearing for the reconciler-vs-delete CLEAN verdict | One focused unit probe; cheap, do first |
| A36 | UI reachability during the account-change pause banner/conflict dialog (assumed non-modal in #350's repro) | Visual check during the A1 run |

**Coverage notes:** PRs #296/#300/#303/#306(except A16)/#308/#312/#314(except A23)/#318(except A22)/#325(deferred rows above)/#339(except A24)/#340(A25) were swept; rows already device-passed are excluded. Bundles merged before 2026-07-10 (B1/C1/D1/D2) were not re-mined — #326's general pass (A18) folds in their family legs; if completeness beyond that is wanted, sweep their PR bodies once before R5's device leg.

---

## Appendix B — Open maintainer decisions gating release items

Excluded as **already ruled**: PR #342 MD-1/2/3 and PR #343 MD1/MD2 (ruled in PR review comments 2026-07-13; #343's carry an explicit override-before-implementation window); tail-plan H2/J1a-1 and #331's fork (de-facto ruled by commits on `fix/263-tail-bundle`, ratified at R1 review); #218/#221/#230/#301/C2/#330/#332 (all resolved — see the merged PRs #306/#325/#314/#284 and the decision records on #330/#332). MD-2c (`automaticallySync` flip) is a labelled out-of-scope escalation in the #316/#335 plan, not an awaiting decision.

| MD | Decision | Gates | Where |
|---|---|---|---|
| MD-1 | **#326 family-pass logistics:** reconcile the dev-install-vs-TestFlight contradiction (C2 above; epic's 2026-07-13 "no dev-install" note is newer), set the "app more complete" bar (this doc reads it as post-R3), obtain the son's consent (incl. the #232 permission-revoke), verify his Apple ID is teen- not child-classified for TestFlight, choose internal-vs-external tester (external ⇒ Beta App Review ~1-2 days). | R10 and the whole Batch-4 device debt | #326; epic #263 Wave 6 note |
| MD-2 | **V1-sunset sequencing:** when to declare `release/v1` frozen and archive it, and the #330-closure criterion ("V1 adoption tailed off" — pick a threshold). No code pending either way. | R16; #330 closure | #330 decision record; branching-strategy memory |
| MD-3 | **Phased vs immediate release** — trade-off analyzed at R14 (phased protects the fleet, prolongs the mixed window; new users get V2 instantly regardless). | R14 (submission) | no issue — this doc |
| MD-4 | **Release-notes sign-off** — assembled text incl. the #332 verbatim note and #310 wipe-caveat consistency. Agent drafts, maintainer approves. | R12 (submission) | #332; `audit.md:160` |
| MD-5 | **CloudKit prod-schema deploy timing** — this runway recommends once, post-R3, pre-TestFlight (schema is additive-only once deployed). Execution is maintainer-only (Console access). | R7 → R10 | #346 |
| MD-6 | **#322 Xcode 27 cutover** — recommendation on the issue ("evaluate on a branch now, cut over at GM ~Sept") is unratified, but per its own body it does **not** gate a summer-2026 submission (store floor = Xcode 26 since 2026-04-28; Xcode 27 mandate predicted ~April 2027). Decide only which toolchain V2's *submission build* uses. | R10/R15 toolchain choice only | #322 |
| MD-7 | **Two-owner lock-code hardening** — audit issue 7 downgraded to probe P1 + "cheap aggregate-all-zones hardening worth shipping regardless" (`audit.md:248`). Decide whether to ship the hardening before release without waiting for the probe. | A18 / release hardening | #326 |

---

*Plan-only. This document plans the release runway; it fixes nothing and closes nothing. Implementation of each runway item is a separate session per the sequential-bundle rule.*
