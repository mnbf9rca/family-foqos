# Family-share compatibility

Tracking: [#480](https://github.com/mnbf9rca/family-foqos/issues/480). Code baseline: `8aa64df9f0380252231664d138b0c23028a43aff` (`main`). This is a design for implementation, not an implemented change.

## Decision

Keep the family protocol backward compatible rather than introduce a family-wide version number. Treat each command type as an immutable operation contract, distinguish unsupported commands from failed reads, and freeze the existing lock-code format. Reject malformed lock-code scopes instead of broadening them to all children. Make pending-command copy describe the evidence available.

Do not add a lock-code version field or a child compatibility report in this change. Neither enables a currently planned operation, and neither fixes the already-shipped readers that need help most. The conditions for adding them are below; a future incompatible writer is explicitly outside the supported contract, not silently allowed by this decision.

The family share may acquire new fields or record types when justified. Profiles, sessions, tags, and locations remain in the owning account's private `DeviceSync` database. There is no new remote profile-management capability.

## Evidence

Paths below are relative to the repository and refer to the baseline above unless another revision is named.

| Finding | Checkable source |
| --- | --- |
| Commands contain a raw-string discriminator and no payload/version field. The only operations are `resetEmergencyCount` and `resetLockCodeThrottle`. | `Foqos/Models/FamilyCommand.swift`: `FamilyCommandType`, `RecordKey`, `init?(from:)` |
| Unknown types fail the same failable initializer as missing IDs/dates. The command fetch sets `hasFailures`, excludes that record, and returns `isConnected == false`. Other decoded commands still run. | `Foqos/CloudKit/CloudKitNetworkService+Commands.swift`: `fetchPendingCommands`, `resolvePendingCommandFetch` |
| That false connectivity becomes `.failed`, including the background-refresh result. It does not itself erase the separately refreshed lock-code cache. | `Foqos/Utils/LockCodeManager.swift`: `processPendingCommands`, `commandRefreshResult`, `ChildSharedDataRefreshResult.combine`; `FoqosTests/ChildSharedRefreshTests.swift` |
| Processing applies recognized commands, records their UUID in a local replay ledger, then deletes them. Unknown commands never reach this path. Age cleanup separately deletes raw command records older than seven days, including unknown types. | `LockCodeManager.processCommand`, `applyCommandIfNeeded`; `CloudKitNetworkService+Commands.swift`: `cleanupStaleCommandsInZone`; `CloudKitNetworkService.swift`: `staleCommandMaxAgeDays = 7` |
| Command names are deterministic by operation, child account, and sending parent. A name collision counts as already pending. The parent probes record existence five times, three seconds apart; disappearance currently becomes “Confirmed by child.” | `FamilyCommand.recordName`; `CloudKitNetworkService.sendCommand`, `commandIsPending`; `Foqos/Views/Parent/ParentDashboardView.swift`: `pollForConfirmation`; `ParentResetCommandStatus.swift` |
| A fresh command cannot age out during the fifteen-second probe. An `alreadyPending` re-tap instead probes an older record, which child cleanup runs before fetch and can delete unapplied after seven days. Normal processing deletion follows application on one device; commands target an account and do not prove every device applied them. | `CloudKitNetworkService.sendCommand`, `commandIsPending`; `LockCodeManager.processPendingCommands`, `processCommand`; `DeviceHeartbeat.recordName` |
| Lock hashes use lowercase SHA-256 hex of UTF-8 `code + salt`, with a base64-encoded 16-byte salt. Scope writes are `all`, or `specific` with a child ID. Missing, unknown, wrong-type, and incomplete scope metadata currently fall back to all children. | `Foqos/Models/FamilyLockCode.swift`: `hashCode`, `generateSalt`, CKRecord conversion |
| The production lock-code writer separately patches a fetched CKRecord. Merely adding a field to `toCKRecord` would miss this writer; an old writer can preserve an unknown version field while replacing its hash/scope payload. | `CloudKitNetworkService+LockCodes.swift`: `saveLockCode` |
| Child lock-code fetch failures preserve the last persisted codes. A connected empty result clears them. Parent fetch currently silently drops failed/undecodable rows. Some UI gates depend on whether the cache is nonempty. | `CloudKitNetworkService+LockCodes.swift`: both fetch methods; `LockCodeManager.resolveLockCodes`, `canVerifyCode`; `Foqos/Utils/ProfileEditGate.swift`; `Foqos/Models/SavedLocation.swift`: `requiresLockCodeToModify` |
| Heartbeats are per device, have no app/protocol version, and are written on profile activation. FamilyMember describes an account, not an installation, and has no version. | `Foqos/Models/DeviceHeartbeat.swift`, `FamilyMember.swift`; `Foqos/Utils/HeartbeatManager.swift`: `writeHeartbeat`; `StrategyManager.swift`: heartbeat call |
| The locally available `release/v1` revision has the same lock-code hash and scope fallback, but no FamilyCommand or DeviceHeartbeat model. It cannot report an unsupported command that it never reads. | `589bee9228abb5b32cc3506f7c0e23782a571d03`: `Foqos/Models/FamilyLockCode.swift`; `git ls-tree -r --name-only <revision> Foqos` |
| Profile schema handling protects readers that already understand the schema gate; it cannot teach a pre-gate binary to respect a new field. The family plane has no such gate today. | `Foqos/Models/BlockedProfiles.swift`: `isNewerSchemaVersion`; `Foqos/CloudKit/SyncEngine/SyncApplyService.swift`: newer-schema branch; historical [upgrade audit](../../audits/v1-v2-family-upgrade-audit.md) |

The seven days are an age-cleanup threshold, not a delivery deadline or a dashboard polling duration. Cleanup runs opportunistically. The parent stops probing after about fifteen seconds and keeps a view-local waiting state. For a fresh save, normal command processing removes the record after local application; the cleanup ambiguity concerns an older `alreadyPending` request. The dashboard does not receive that distinction from `sendCommand` today. No compatibility design may infer an app version, delivery, or completion from elapsed time alone.

## 1. Unknown commands: accept candidate (a)

Keep `FamilyCommand` as the executable model with its existing two-case enum. At the CloudKit decoding boundary distinguish three outcomes: supported command, unsupported command type, malformed record. A small local decode-result enum or equivalent typed error is enough; no generic protocol framework or family-wide version field.

Validate the existing envelope before declaring a type unsupported: the record type, UUID, nonempty string command type, nonempty target/sender strings, and creation date must be valid. Retain the existing query predicate restricting results to the current child's target ID. Only a valid envelope with an unrecognized type is unsupported. Missing/non-string/empty type is a malformed record, not forward compatibility.

| Read outcome | Child behavior | Refresh outcome |
| --- | --- | --- |
| Supported | Existing apply-once ledger and deletion behavior | Existing `.newData`/`.noData`; apply/delete failure remains `.failed` |
| Unsupported type with valid envelope | Leave the record alone; no side effect, ledger entry, acknowledgement, or processing deletion | Does not set `hasFailures`; alone yields `.noData`, with an applied supported command yields `.newData` |
| Malformed record, row failure, zone failure, missing user identity | Preserve current failure reporting and keep processing any independently valid commands | `.failed` |

Keep a diagnostic for unsupported input, separate from an error, including the unrecognized command discriminator truncated to 64 characters so mixed-version behavior can be diagnosed. The discriminator is app vocabulary within the trusted-participant threat model; do not log other field contents or personal identifiers. The normal stale-record sweeper remains unchanged: “leave alone” applies to command processing, not indefinite retention. A record may be processed after the child updates if it still exists; delivery is not promised after expiry.

The immutable command contract is the version mechanism: existing raw strings keep their current meaning and required envelope. A future operation with different semantics or mandatory payload uses a new discriminator, never optional fields that an old reader would ignore while executing the old operation. Readers of old commands remain supported. No command rewrite, replay-ledger migration, polling expansion, or registration of future command types belongs in this change.

## 2. Lock codes: freeze the format; defer candidate (b)

The existing `FamilyLockCode` record type is the legacy format contract. Continue writing the current hash construction and current scope vocabulary. Do not introduce a stronger hash, a new scope, a version-dependent default, or a migration of existing records here.

Tighten scope decoding at its shared model boundary. Accept explicit `all`; accept `specific` only with a nonempty string child ID. Retain the existing historical default only when `scopeType` is absent. Reject a present wrong-type, empty, or unknown scope, and reject `specific` with an absent/wrong-type/empty child ID. Never turn those cases into `allChildren`. Ignore irrelevant extra fields on an explicitly valid legacy record, as old and new writers must remain interoperable.

Route a rejected lock-code record through the existing fetch-failure/cache-preservation path. Make the parent fetch fail on a failed or undecodable row too, preserving its previous list and surfacing its existing error rather than publishing a partial list as authoritative. A malformed record must not be interpreted as “the parent removed the PIN.” This is validation of the current contract, not support for future scopes.

One malformed row therefore freezes the child's whole cached code list: subsequent PIN changes/removals are not applied until a complete readable fetch succeeds, and a first fetch with no cache cannot establish a lock. The parent cannot select an undecodable row for individual deletion. Existing “Reset Family Sharing” → “Reset Rules Only” deletes by query without decoding (`resetFamilySharing(clearEverything: false)`), erasing all lock codes and pending commands while retaining membership; after successful removal and a readable fetch, the parent can set the PIN again. This is disruptive recovery for invalid data, not an automatic migration or a guarantee that reset succeeds offline. No new repair UI is proposed.

Preserve the current offline-cache policy. This change does not claim that a previous PIN is safe after receipt of a future incompatible replacement, or that an empty cache is a read-only compatibility state. Those claims would be false: `canVerifyCode` feeds UI gates, and the current cache model has no representation of “a lock exists but this app cannot understand it.” Do not implement an unknown-format fallback by dropping the record and carrying on.

**Why no `formatVersion = 1` now:** both existing generations already agree on the one format. Old readers ignore a new version field and still broaden an unknown scope; old parent writers can overwrite the payload while leaving that field intact. A marker alone would create a false promise of safe evolution. Making it useful requires coordinated reader/cache/write behavior without any new hash or scope currently requested. Keep that work with the first concrete format change.

**Requirement for that future change:** choose the new hash/scope semantics first, then design their compatibility boundary. Do not publish incompatible payloads into the existing record format while pre-gate readers/writers can participate. An isolated new record type or an explicit enrollment/migration boundary may be necessary; fields alone cannot retrofit safety. Keeping a legacy representation is acceptable only where it preserves exactly the same effective code and scope. A legacy fallback that broadens a new restricted scope is forbidden.

If a future design uses a version field, prefer one integer format version covering the entire hash encoding and scope semantics, rather than independent hash/scope/app versions. Absent means the documented legacy format; unknown means unreadable, never legacy. Updated readers must preserve that unreadable state across restart/offline, keep lock restrictions active, refuse PIN verification using obsolete cached credentials, and offer an update path. Updated parent writers must not downgrade or edit unreadable records, including through fetch-then-patch helpers. Complete compatible reads or confirmed family revocation must have an explicit recovery rule. Ship and test those readers before enabling the incompatible writer. This is a prerequisite for the future feature, not implementation scope now.

## 3. Parent feedback: defer candidate (c); remove unsupported certainty

Do not add capability advertisements, app-version heartbeats, command receipt records, or a new child write on every refresh now. The current sender can emit only the two operations current children already understand. The historical child with neither command nor heartbeat support cannot supply the proposed report. New reporting machinery would therefore not distinguish that child from an offline/current child during the mixed window that exists today.

Make the existing status honest without guessing:

- Pending record: “Sent — not yet confirmed. Open Foqos on the child's device; both devices may need an app update.”
- Record absent: “Request no longer pending.” Replace the `.confirmed` state/name and success presentation so absence does not claim execution.
- Probe error: keep the unconfirmed state; do not turn an error into “update needed” or success.

Use one absence label for both fresh and already-pending saves. Returning a save outcome to the dashboard could preserve the more specific “Applied on one of the child's devices” signal for fresh saves, but adds plumbing solely for that distinction. The uniform label is the smaller truthful design.

Keep the existing probe count and queue expiry. This change offers a useful next step immediately, without claiming that an update is definitely required or that waiting seven days will confirm the operation. It does not introduce a reliable acknowledgement protocol.

Add explicit unsupported feedback when the first new command/format actually creates a compatibility distinction between clients implementing this design. The report must identify an observed incompatibility, not merely an older marketing version. Missing or stale reports mean unknown. A per-device heartbeat extension is the first existing location to evaluate because FamilyMember is account-scoped; a dedicated receipt can be smaller if the requirement is per command. Neither is selected speculatively here.

That future design must address observations without profile activation, account versus device granularity, command UUID/generation versus reused record names, clearing status only after a successful compatible read, report-write failure, and stale/offline reports. Reporting must not forge a fresh Screen Time authorization observation. A report from one device never proves every device on that child's account supports or applied the command. These requirements explain why an unqualified `needsUpdate` Boolean is insufficient.

## Mixed-version behavior

“Baseline” below means a family-capable client before this design; “updated” means this design, still writing the legacy lock format and the existing command strings.

| Pair or input | Supported behavior / limit |
| --- | --- |
| Updated parent, baseline child | Same PIN/hash/scope and existing reset types; no new payload is sent. Parent copy stays unconfirmed without evidence. Baseline child behavior is unchanged. |
| Baseline parent, updated child | Existing codes and reset types remain readable. Child does not require a new field, heartbeat, or report from the parent. |
| Parent supporting commands, historical child without command support | PIN format remains compatible. Resets are not executed by that child; new parent copy suggests opening/updating without falsely diagnosing the cause. No backport is implied. |
| Future sender, updated child, unknown command type | Valid unsupported envelope is left pending until a reader understands it or normal cleanup removes it; other refresh work succeeds. Future sender must accept unconfirmed delivery. |
| Future incompatible lock format, any pre-gate client | **Not supported or authorized by this design.** An auto-update window is not a format-migration gate. Keep writing the legacy format until a separately reviewed migration meets the requirements above. |
| Mixed devices on one child account | Preserve current account-targeted command semantics. Neither pending status nor record disappearance proves per-device completion. |

This design assumes no deadline by which auto-update has replaced every installed reader. Its immediate changes tolerate an arbitrarily long mixed window without requiring a rollout service or minimum-app-version registry. It cannot repair historical clients remotely or guarantee command delivery while an app does not run.

## Builder acceptance

1. Add a small CKRecord decoding test table using the actual production command classifier: the two known types, a well-formed future type, unknown type with malformed envelope, and empty/non-string type. Exercise the fetch reducer with known+unknown and known+failed inputs so the test would catch the old `hasFailures` behavior. The existing pure `resolvePendingCommandFetch` and `commandRefreshResult` seams suffice after exposing the actual classifier; no CloudKit client abstraction is needed.
2. Preserve `FamilyCommandApplyTests`, `FamilyCommandSaveOutcomeTests`, and `ChildSharedRefreshTests`. Through diff review verify unsupported outcomes cannot reach `applyCommandIfNeeded` or `deleteCommand`, enter the ledger, or suppress supported siblings, and that seven-day raw-record cleanup is unchanged. No log-capture seam is required.
3. Add CKRecord tests for the real lock-code decoder: absent scope retains legacy all; explicit all and valid specific pass; wrong-type/unknown/empty scope and incomplete specific fail. Verify a fixture written with the legacy hash/salt still accepts its PIN and rejects a different PIN. Preserve cache round-trip and `LockCodeFailClosedTests`; extend fetch-result coverage for parent row/decode failures without introducing a network mock hierarchy.
4. Update `ParentResetCommandStatusTests` for pending, absent, and idle. Review the actual dashboard's icon/color selection and early exit after “no longer pending,” not just its strings; it must no longer represent disappearance as child-confirmed success. Keep genuine probe failures unconfirmed.
5. Diff-review the mixed-version contract: no changed hash/scope writer, new command discriminator, new shared field/type, dependency, or private-profile payload on the family share. No schema deployment is needed for these immediate changes. Existing schema-drift tests remain unchanged.
6. Where family CloudKit test devices are available, queue a valid synthetic unknown command and a supported command to the same child, then open the child app: the supported operation executes, the unknown record remains, and refresh is not failed solely by the unknown type. Check pending/absent copy on the parent. Record the walkthrough as not run if the family setup is unavailable; deterministic decoder/reducer tests and diff review remain required.

Builders run the focused XCTest classes through the repository's `scripts/xcode-stream.sh` workflow. The spec PR itself requires prose/diff checks and independent design review, not an Xcode run. Leave the reviewed spec PR open and ready for review; its commits land with the implementation PR, per the human's ruling.
