# Open the protected model store after reboot (#572)

A background launch 86 seconds after reboot trapped in the global SwiftData container initializer. The crash report records that the phone had never been unlocked since boot. It omits the store error. A Live Activity is one possible wake source. Handle unavailable storage at the app entry point regardless of who launched it. [Incident](https://github.com/mnbf9rca/family-foqos/issues/572) · [Apple DTS on background launches](https://developer.apple.com/forums/thread/760711)

## Startup contract

One process-wide main-actor owner provides the existing production ModelContainer to both the app and App Intents. Before opening it, establish access to data protected until first authentication. UIKit’s protected-data flag can be false on an ordinary relock. On a cold locked launch, allow an existing readable store to proceed (StartupRecoveryLocalState.readStore opens SQLite read-only without creating it). If access cannot be established, wait. Once open, retain the same container across later locks. Preserve existing file protection, schema, store location and screenshot-demo configuration.

Before access is established, instantiate no defaults-backed singleton and read no shared-defaults accessor. This includes AppModeManager (Child mode and onboarding), StrategyManager (persisted remote-session cache), ProfileSyncManager (sync enablement) and SharedData.deviceSyncId (which creates an ID if missing). Apply this rule to the app root, launch handlers and App Intent entry points, including authentication-policy evaluation.

While waiting, render a minimal unlock state. Keep model queries, recovery classification, defaults migrations, demo seeding, sync attachment, scheduling refresh and model-dependent work dormant. Do not create a replacement store, infer a fresh install, or erase inaccessible defaults. Register launch-time system handlers on time. Protected-data-available and foreground entry both retry. Register the unlock observer before checking availability so an unlock cannot be missed, even on a background launch without a scene. A ready owner returns the same instance on repeated or concurrent entry. A real open error with available data gets a redacted error and a foreground retry path. No crash, destructive repair, or endless immediate retry.

Capture startup recovery evidence **after access is established but before opening the container**, creating recovery-related singletons, or running migrations that can change the evidence. Retain that snapshot across an ordinary open retry. Only a successful open releases the store gate; the existing recovery coordinator still controls Home and sync. Preserve normal routing of shares, pending links and post-unlock Shortcuts. A locked intent must fail promptly without prompting a store open through an unresolved dependency; a background fetch must complete exactly once.

## Boundaries

Build2 owns app bootstrap, App Intents’ model dependency, and its launch tests. Build1 owns all session logic. The two streams share only a sequenced version bump. Acceptance uses simulator-hosted dependency injection for pre-unlock and store failure. Actual keybag protection and a reboot-triggered Live Activity wake require the normal release-candidate device pass. [Batch ruling](https://github.com/mnbf9rca/family-foqos/issues/570#issuecomment-6993139911)
