# Defect Audit Remediation Plan (2026-07-02)

Tracking epic for the 67 issues (#195–#261) logged by the 2026-07-02 multi-agent defect audit. Handover docs: [docs/handovers/](https://github.com/mnbf9rca/family-foqos/blob/audit/2026-07-02-defect-handovers/docs/handovers/README.md) (PR #262).

Issues are bundled into **21 PRs** by shared root cause / shared files, sequenced into **5 waves**. Within a wave, bundles are independent and parallelizable — **except sync-layer bundles (A×, E2), which all touch `SyncCoordinator`/`ProfileSyncManager` and should land serially to avoid rebase pain**. One PR per bundle; one feature branch each; handover docs are per-issue.

## Wave 1 — criticals, no dependencies

- **E1 · Profile save/clone pipeline** (`BlockedProfileView` save ordering, then clone fixes ride on it)
  - [ ] #198
  - [ ] #209
  - [ ] #223
  - [ ] #234
- **A1 · Reset-sync safety** (SyncResetRequest lifecycle: ordering, tombstone, cleanup)
  - [ ] #195
  - [ ] #202
- **B1 · Lock-code gating audit** (who is gated when, per the AGENTS.md mode table; includes the #196 copy fix)
  - [ ] #197
  - [ ] #199
  - [ ] #211
  - [ ] #251
  - [ ] #244
  - [ ] #196
- **C1 · DeviceActivity interval validation** (clamp/reject <15-min and zero-length intervals; groundwork for C2)
  - [ ] #212
  - [ ] #228
- **Investigation (no code): confirm or refute the two disputed findings** — outcome feeds C2 and D1
  - [ ] #260
  - [ ] #261

## Wave 2 — high-impact, independent

- **D2 · Remote session handling** (`StrategyManager` remote start/stop paths, SharedData identity checks)
  - [ ] #203
  - [ ] #204
  - [ ] #237
- **D1 · Monitor-extension start/stop semantics** (schedule stops respect stop conditions, day-of-week, session origin, `disableBackgroundStops`; shared "background stop policy" helper also resolves #261 if confirmed)
  - [ ] #206
  - [ ] #229
  - [ ] #236
  - [ ] #239
  - [ ] #243
  - [ ] #261
- **A2 · Sync delivery reliability** (push retry queue + notification-throttle coalescing; retry infra is reused by A4)
  - [ ] #201
  - [ ] #200
- **F · Zombie-model safety** (extend SafeQuery/.valid coverage)
  - [ ] #213
  - [ ] #235
- **I · App-group UserDefaults migration ordering**
  - [ ] #217

## Wave 3 — after Wave 1/2 groundwork

- **C2 · Short-interval enforcement (one-more-minute & breaks)** — depends on C1 and the #260 verdict; likely needs an in-process/notification fallback architecture
  - [ ] #207
  - [ ] #214
  - [ ] #205
  - [ ] #260
- **A3 · Sync conflict semantics** (version ties, query-index lag, counter merge, command recordName) — after A2
  - [ ] #218
  - [ ] #219
  - [ ] #221
- **A4 · Location sync integrity** (dangling geofence refs local + remote, updatedAt ping-pong) — after A2/A3
  - [ ] #215
  - [ ] #216
  - [ ] #220
- **B2 · Family command & heartbeat plumbing** (lock-code cache refresh, command processing cadence, duplicate notifications, participant records, mode-switch race)
  - [ ] #208
  - [ ] #230
  - [ ] #222
  - [ ] #232
  - [ ] #241
  - [ ] #231
- **D3 · Session start guards**
  - [ ] #224
  - [ ] #225
- **D4 · Session lifecycle hygiene** (CAS reconciliation identity, notification wipe, duplicate reminders, delete cleanup)
  - [ ] #226
  - [ ] #227
  - [ ] #242
  - [ ] #245

## Wave 4 — lower risk, anytime after Wave 1

- **E2 · List operations sync parity + carousel** (delete/reorder push to sync) — serialize with other sync bundles
  - [ ] #210
  - [ ] #233
  - [ ] #246
- **G · Widget & Live Activity freshness**
  - [ ] #238
  - [ ] #249
- **H · Logging & privacy** (PII in logs, debug-mode exposure, extension log export)
  - [ ] #252
  - [ ] #247
  - [ ] #250
- **B3 · PIN hash hardening** (design + migration work; independent but touches lock-code files — land after B1/B2)
  - [ ] #240
- **J1 · README corrections**
  - [ ] #253
  - [ ] #254

## Wave 5 — last (deletes code other PRs may touch)

- **J2 · Dead code & project hygiene sweep**
  - [ ] #255
  - [ ] #256
  - [ ] #257
  - [ ] #258
  - [ ] #259
  - [ ] #248

## Dependency notes

1. **E1 before #209/#223** (in-bundle: fix save ordering first, clone fixes build on it).
2. **C1 → C2**: validation groundwork before the short-interval fallback architecture; C2 also waits on the #260 investigation (break re-application semantics).
3. **A2 → A3 → A4**: retry/delivery infra first; A4's remote-deletion cleanup reuses it. All A-bundles + E2 serialize (same files).
4. **D1 resolves #261** if the investigation confirms it — one shared background-stop policy helper.
5. **#196 decision is made** (2026-07-02): stopping stays un-gated; B1 only fixes the copy.
6. **J2 last** — dead-code deletion conflicts with everything.
7. Every PR: feature branch, code review before merge, regression tests per the issue's handover doc (`docs/handovers/issue-<n>-*.md`).

_Generated from the 2026-07-02 audit. Tracking epic: [#263](https://github.com/mnbf9rca/family-foqos/issues/263)._
