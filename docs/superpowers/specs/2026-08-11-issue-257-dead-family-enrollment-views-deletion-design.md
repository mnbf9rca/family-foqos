# Issue #257 Dead Family Enrollment Views Deletion Design

## Goal

Delete the unreachable `AddFamilyMemberView` and `EnrollFamilyMemberButton` duplicate enrollment
UIs, plus the `FamilyRole.description` helper that becomes orphaned by that deletion, while keeping
the live parent-dashboard enrollment flow unchanged.

## Current behavior and root cause

The two dead views each create a private `ShareCoordinator`, call `enrollFamilyMember(role:)`, and
attach their own enrollment sheet. Neither view is ever instantiated. The live flow has always
bypassed them: `ParentDashboardView` owns the coordinator, attaches one
`enrollFamilyMemberSheet`, and its Parents and Children buttons call the coordinator directly.

All three paths were introduced together in commit `9a0bdcd`. History searches find no later route
or instantiation of either descriptive dead type. Their presence therefore presents three plausible
implementations to maintainers even though only the dashboard implementation can execute.

## Deletion evidence

The evidence was re-derived from `main` at `eebb04b`.

### Access level and search radius

Both dead types have default internal access. Internal access requires a complete Foqos-module
search. Because these are family-flow views, the sweep was extended across all five production
roots, package sources, unit/UI tests, resources, and the Xcode project:

1. `Foqos`
2. `FoqosWidget`
3. `FoqosDeviceMonitor`
4. `FoqosShieldConfig`
5. `Packages/FoqosShared/Sources`

Each type name appears exactly once, at its declaration. Searches excluding its containing file
find no construction, preview, test, route, or callback reference. History searches outside the
containing file are also empty.

Distinctive dead copy—`How it works`, `Send Invitation`, `share a link`, `Their device will be
linked to yours`, and `person.badge.plus`—exists only in the dead subtrees. Onboarding and
dashboard route searches retain the live `parent-dashboard` screenshot scenario but reveal no
route to either type. `NSClassFromString` is used only to detect `XCTestCase`; SwiftUI cannot
construct these internal structs dynamically.

### Live enrollment boundary

The live path remains:

1. `ParentDashboardView` owns its shared `ShareCoordinator`.
2. The view attaches `.enrollFamilyMemberSheet(coordinator: shareCoordinator)`.
3. Parents and Children buttons call `shareCoordinator.enrollFamilyMember(role:)` directly.
4. `ShareCoordinator` creates/fetches the family share and presents `CloudSharingView` through
   `EnrollFamilyMemberModifier`.

The production regions containing that path will be preserved byte-for-byte. The existing
`#Preview { ParentDashboardView() }` will also remain byte-for-byte. No live coordinator,
CloudKit, sheet-modifier, role, or dashboard logic changes.

### Cascade evidence

Removing a caller can orphan its callees. The two dead views call several shared APIs:

- `ShareCoordinator.enrollFamilyMember` remains live at both dashboard buttons.
- `View.enrollFamilyMemberSheet` remains live on `ParentDashboardView`.
- `FamilyRole.iconName` remains live in dashboard member rows.
- `FamilyRole.displayName` remains live in app confirmation, dashboard rows, and logging.
- `FamilyRole.description` is used only by `AddFamilyMemberView` and becomes dead with it.

`FamilyRole.description` is an internal computed UI-copy property. `FamilyRole` does not conform to
`CustomStringConvertible` or `CustomDebugStringConvertible`; no direct interpolation of a
`FamilyRole` value and no `String(describing:)`/`String(reflecting:)` call relies on it. It has no
Codable, raw-value, CloudKit, migration, or persistence significance. It must be removed with the
dead caller to avoid creating new hygiene debt.

### Persistence, project, and privacy boundaries

- No model fields, enum cases/raw values, Codable shapes, CloudKit record keys, migrations,
  UserDefaults keys, or shared snapshots change.
- Both containing files remain in the file-system-synchronized Foqos root, so project membership is
  unchanged and the pbxproj delta is version-only.
- The deleted subtrees contain no `Log` calls. Privacy must remain 232 files, 500 sites, and zero
  annotations; the baseline file must not change.

## Approved approach

1. Delete the `AddFamilyMemberView` MARK section and declaration from
   `ParentDashboardView.swift`, preserving its trailing ParentDashboard preview.
2. Delete the `EnrollFamilyMemberButton` MARK section and declaration from the tail of
   `ShareCoordinator.swift`.
3. Delete only the internal `FamilyRole.description` computed property from `FamilyMember.swift`.
4. Leave imports, live enrollment types/methods, route strings, and all production behavior
   otherwise unchanged.
5. Bump all configurations from 2.0.12/31 to 2.0.13/32.

## Rejected alternatives

- Leaving `FamilyRole.description` was rejected because the deletion would knowingly create a new
  orphaned helper.
- Refactoring the live dashboard buttons into a component was rejected as unrelated behavior/source
  churn.
- A source-layout unit test was rejected because static deletion evidence is the relevant proof.
  Existing role/route tests, compilation, and the full suite cover the surviving behavior.

## Verification contract

- Dead type names, their distinctive strings, and `FamilyRole.description` have zero live hits.
- Live dashboard enrollment blocks and ParentDashboard preview compare byte-identical to base.
- `enrollFamilyMember`, `enrollFamilyMemberSheet`, `iconName`, and `displayName` retain live callers.
- Parent-dashboard route strings and family-role model behavior remain covered by targeted tests.
- Privacy remains 232/500/0 and version gate reports 2.0.12/31 to 2.0.13/32.
- Formatting, C2, sync, diff, full tests, and serialized Debug build pass.
- Independent deletion review reports no unresolved Critical or Important findings.
