# V1 Library store

`v1-library.store` is a consolidated SQLite backup of the synthetic Library persona's V1 store, created by release/v1 commit `589bee9` (1.31.3) on iOS 26.5. Source run: `/private/tmp/family-foqos-v1-v2.moazsd8c`, captured `v1-app-group/Library/Application Support/default.store`. Python's SQLite backup API included the captured WAL contents into this single file; no sidecar files are needed.

The fixture contains 24 `RC Library` profiles, one completed Manual session, and one synthetic `RC Study` location. It has all three V1 entities and no `SavedLocation.syncVersion` column. It reproduces issue #546's mandatory-attribute migration failure before the fix. SHA-256: `5f08fc78abcb62cb1423fbbb7d355fe6d5737d085baf7d247ab28d28b5d1414a`.

`V1StoreMigrationTests` copies it to a fresh temporary directory, opens the production `AppModelStore` schema/configuration, verifies data preservation and migration defaults, and removes the temporary files. Never replace this input with a store opened by V2.

The audit against V1 found `SavedLocation.syncVersion` was the only added non-optional attribute without a declaration default on an existing entity. Added `BlockedProfiles` and `BlockedProfileSession` attributes were optional or already defaulted; `SavedTag` is a new entity, so there are no V1 tag rows needing attribute defaults.

Apple's [lightweight migration guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmLightweightMigration.html) describes schema-inferred store migration. [Model your schema with SwiftData](https://developer.apple.com/videos/play/wwdc2023/10195/) explains that model declarations supply that schema. The captured-store regression verifies that the declaration default, unlike the initializer's parameter default, supplies the missing value for V1 rows.
