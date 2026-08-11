# Issue #259 Bogus Supported Info.plist Key Deletion Design

## Goal

Delete the unrecognized `<key>Supported</key><false/>` pair from the main app Info.plist without
changing any real target capability or duplicating build-setting-owned configuration.

## Re-derived evidence

The audit was repeated at `main` `f7278df`, version 2.0.13/32, privacy floor 500.

### Target-plist inventory

Four production target plists exist:

- `Foqos/Info.plist` contains `Supported = false`.
- `FoqosWidget/Info.plist` does not.
- `FoqosDeviceMonitor/Info.plist` does not.
- `FoqosShieldConfig/Info.plist` does not.

`Packages/FoqosShared/Sources` is the fifth production root but has no target Info.plist. All four
source plists pass `plutil -lint`.

An exact sweep across all five production roots, tests, UI tests, scripts, and the Xcode project
finds no string literal read of `Supported`, no `INFOPLIST_KEY_Supported`, and no generic runtime
dependency on unknown keys. Existing bundle-dictionary reads request only explicit version/build
metadata.

### History correction

Commit `5ed7d75` added the pair during the original Live Activities implementation. It was not left
behind by a later encryption-key removal; the bogus pair predates that configuration. The history
matters because the correct remediation is deletion, not restoring or renaming an encryption key.

The actual settings are already owned by both main-target build configurations:

- `INFOPLIST_KEY_NSSupportsLiveActivities = YES`
- `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`

The baseline built main-app Info.plist proves all three generated results: Live Activities true,
non-exempt encryption false, and bogus Supported false.

## Approved approach

Delete exactly these two source lines from `Foqos/Info.plist`:

```xml
<key>Supported</key>
<false/>
```

Do not add a replacement source key. Keep real capability ownership in build settings. Bump all 12
configurations from 2.0.13/32 to 2.0.14/33. The deletion removes no source file or `Log` call, so
privacy must remain 232 files / 500 sites / 0 annotations and neither privacy baseline changes.

## Rejected alternatives

- Adding `NSSupportsLiveActivities` to the source plist was rejected because it already comes from
  both build configurations; a second owner invites drift.
- Adding a repository-text unit test was rejected as decorative. Plist parsing, generated-product
  inspection, build, and the full suite are the relevant proof.

## Verification contract

- All four source plists pass `plutil -lint`.
- Exact `Supported` key/configuration/runtime reads have zero repository hits.
- Debug build succeeds.
- The built main-app Info.plist has no `Supported` key, retains `NSSupportsLiveActivities = true`,
  and retains `ITSAppUsesNonExemptEncryption = false`.
- Version, privacy, formatting, C2, sync, diff, and full-suite checks pass.
- Independent review has no unresolved Critical or Important findings.
