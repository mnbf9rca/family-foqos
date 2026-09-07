# Security Policy

## Security model

Family Foqos is an iOS app that blocks distracting apps and websites behind a physical action such as tapping an NFC tag or scanning a QR code. Its family features let a parent lock a child's profiles so that the child needs a four-digit code to edit or delete them. The app is a friction tool, not a security product: it prioritizes **honest limits and the child's privacy over the appearance of control**. Blocking is enforced by Apple's Screen Time frameworks (FamilyControls, ManagedSettings, and DeviceActivity), and the parental lock code is, in the words of the source, "a low-stakes secret: parental friction, not a credential guarding high-value data" (`Foqos/Models/FamilyLockCode.swift`).

The app runs no servers. Its only network peer is Apple CloudKit, used for two purposes: syncing one person's data between their own devices, and carrying a small family-sharing plane between a parent and a child. It contains no analytics or crash-reporting SDK and one third-party dependency, the CodeScanner QR library, pinned by Swift Package Manager.

Behavior is defined by the code and by [App Modes and Locking](docs/app-modes-and-locking.md). This document records the threats considered, what the app does about each, and what risk remains.

### Threat model: what Family Foqos defends against

- **A child editing or deleting a locked profile without the code.** In Child mode, locked profiles, locked saved locations, and locked emergency settings require the parent's lock code before the edit form can be saved or the item deleted. The code is verified offline against a cached salted SHA-256 hash, so a child cannot escape the check by going offline. Failed attempts are throttled: 30 seconds after 3 failures, rising to 15 minutes after 10. A parent can clear the throttle remotely with a family command.
- **A child leaving parental control silently.** The "Remove Parental lock" action in Child mode asks for the lock code whenever one has been received, and then hands over to Apple's own leave-share sheet. Mode changes are not possible from the parent's device; the parent configures the child's device in person.
- **An adult locking another adult's phone.** Locking works only for an Apple Family child account. After a device accepts the family share, the app asks the operating system for child-level Screen Time authorization; an adult account is refused by iOS and the device becomes a parent, not a child. The README states this is deliberate and will not change.
- **Escaping a strict session by deleting the app.** A profile with Strict enabled sets `denyAppRemoval` on the managed settings store, so iOS refuses to delete the app while the session runs. Without Strict, deletion works, and the profile editor says so.
- **A parent reading the child's data.** The family share carries only what the family features need: lock-code records (hash, salt, scope), a family-member record (display name, role), a child-to-parent heartbeat (device name, vendor identifier, Screen Time authorization status, time), and two parent-to-child commands (`resetEmergencyCount`, `resetLockCodeThrottle`). Profiles, sessions, tags, and locations sync only inside the owning iCloud account's private database and never cross the share. Parents cannot start or stop sessions, push profiles, or scan tags for the child.
- **Secrets and personal data in logs.** The lock code is never stored or logged in plaintext. A build-phase lint (`scripts/check-log-privacy.rb`) refuses log calls that interpolate raw errors, URLs, coordinates, family identities, or tag identifiers, and refuses direct use of `Logger`, `NSLog`, or `os_log`. Log export redacts the device name and omits family names and record identifiers unless you turn on the roster option, which the export screen describes before you enable it.
- **Demo data reaching a release.** Screenshot demo mode is compiled out of non-debug builds and seeds an in-memory store only.
- **One account wiping another.** Reset Sync deletes and recreates the `DeviceSync` zone in the current iCloud account's private database. It cannot touch another account or the family share.

### Out of scope

- **Anyone with device-level access.** The app mode, the cached lock-code hash, the throttle counters, and the emergency-unblock ledger live in the app's `UserDefaults`. A jailbroken device, an edited backup, or a debugger can change any of them. iOS app sandboxing is the boundary; the app adds none.
- **Offline brute force of the lock code.** The code is four decimal digits and its salted SHA-256 hash is readable by the child's iCloud account. Anyone who extracts the hash can try all 10,000 codes. The maintainer ruled this proportionate for a friction code (issue #240) and plans no further hardening.
- **Defeating Screen Time itself.** Turning off the Screen Time permission, using a Screen Time passcode, restoring the device, or changing the clock are outside the app's control. The app does not observe these events directly. A child device writes a heartbeat only when a session starts, and the parent's dashboard raises a "permissions lost" or "device check-in" alert from that heartbeat, the latter after 24 hours of silence.
- **Stopping a session.** The lock code gates editing and deleting, never stopping. Deep links, printed QR codes, and written NFC tags carry the profile's UUID as a plain URL, and "specific tag" stop conditions compare a tag's hardware identifier or an unkeyed hash of the QR content. These are identifiers, not secrets: a photograph of the QR code, a copied tag, or the same link opened from a message stops the session if the profile allows that stop method. Physical unblock is friction against habit, not against intent.
- **Apple's accounts and infrastructure.** iCloud sign-in, CloudKit access control, and Family Sharing membership are Apple's. The app trusts what CloudKit and FamilyControls report.
- **The V1 App Store build.** This document describes the current `main` branch. The shipped V1 build predates the throttling and leave-share gating above; [the V1 to V2 family upgrade audit](docs/audits/v1-v2-family-upgrade-audit.md) records the differences, including that a V1 child can leave the family without a code.

## Known risks and accepted residuals

1. **Every share participant is trusted equally.** The parent's device upgrades every accepted participant to read-write on the whole `FamilyPolicies` zone so that children can write heartbeats, and no device checks who wrote a lock-code record, member record, or command before applying it. A participant running a modified copy of the app could set a lock code or clear a throttle for the family. The share is invitation-only with no public link, so this reduces to inviting only people you trust.
2. **The throttle is a client-side counter.** Deleting and reinstalling the app clears it, along with everything else in the child's local state.
3. **Manual stop overrides a physical tag.** Stop conditions combine with "or", and "Tap to stop" takes priority. A profile with both "Tap to stop" and a specific tag enabled can be stopped without the tag, and the editor does not warn about that combination.
4. **Links and Shortcuts can stop sessions.** A profile whose stop conditions include the written tag or printed code accepts its deep link from any source, and the Stop Profile shortcut accepts any profile with "Tap to stop" enabled. Both paths honor the per-profile "Disable Background Stops" toggle, which is off by default.
5. **Lock gates live in views, not in the model.** Editing and deleting a locked item is blocked by hiding the save and delete controls; the underlying update and delete functions do not check the lock. No shipped code path reaches them without the view, but a new caller could.
6. **The heartbeat carries the device name.** iOS device names often contain the child's first name. The parent's dashboard shows it; nothing else in the app does.
7. **The parent sees no emergency history.** A child can perform three emergency unblocks per reset period, counted on the child's device. The parent can reset the count but is not told when or how often it was used.
8. **The diagnostics screen ships in release builds in every mode.** It shows the active profile and session internals and offers log export. Everything it shows is already on that device, but log lines include profile names.
9. **Time comes from the device clock.** Scheduled starts and stops, break deadlines, and one-more-minute deadlines use local wall-clock time with no trusted time source.

## Data at rest and in transit

The app's own store is SwiftData in the app's private container. The widget, shield, and device-monitor extensions read only the app group's `UserDefaults` suite and snapshot files; the cached lock codes, throttle state, and emergency ledger are not written to the app group. The app does not use the keychain.

In CloudKit, one person's profiles, sessions, tags, locations, and emergency settings live in the `DeviceSync` zone of their private database, readable only by devices signed into that iCloud account, with CloudKit's default encryption and no additional field encryption. The family plane lives in the `FamilyPolicies` zone of the parent's private database and reaches child devices through a CKShare with public permission set to none.

## Reporting a vulnerability

Open a [GitHub security advisory](https://github.com/mnbf9rca/family-foqos/security/advisories/new) rather than a public issue for anything exploitable. Include the app version, the iOS version, the app mode (Individual, Parent, or Child), and whether family sharing was in use. Do not attach log exports that include the family roster. Reports about risks explicitly accepted above are welcome as ordinary issues if you believe the assessment is wrong.

## Security updates

Fixes ship as ordinary app updates through TestFlight and the App Store; there is no separate advisory channel. Every change to `main` arrives through a signed commit on a reviewed pull request, CodeQL runs weekly, and the single external dependency is pinned by commit.
