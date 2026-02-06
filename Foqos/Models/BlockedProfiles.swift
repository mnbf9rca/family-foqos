import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
@preconcurrency import SwiftData  // ReferenceWritableKeyPath in SortDescriptor lacks Sendable conformance

@Model
class BlockedProfiles {
    @Attribute(.unique) var id: UUID
    var name: String
    var selectedActivity: FamilyActivitySelection
    var createdAt: Date
    var updatedAt: Date
    var blockingStrategyId: String?
    var strategyData: Data?
    var order: Int = 0

    var enableLiveActivity: Bool = false
    var reminderTimeInSeconds: UInt32?
    var enableBreaks: Bool = false
    var breakTimeInMinutes: Int = 15
    var enableStrictMode: Bool = false
    var enableAllowMode: Bool = false
    var enableAllowModeDomains: Bool = false
    var enableSafariBlocking: Bool = true

    var physicalUnblockNFCTagId: String?
    var physicalUnblockQRCodeId: String?

    var domains: [String]?

    var schedule: BlockedProfileSchedule?

    var geofenceRule: ProfileGeofenceRule?

    var disableBackgroundStops: Bool = false

    // Pre-activation reminder for scheduled profiles
    var preActivationReminderEnabled: Bool = false
    var preActivationReminderMinutes: UInt8 = 1 // 1-5 minutes

    var customReminderMessage: String?

    // Managed profile fields (parent-controlled)
    var isManaged: Bool = false // If true, requires lock code to edit/delete
    var managedByChildId: String? // Which child this managed profile is for (for per-child code lookup)

    // Device sync fields (same-user multi-device sync)
    var syncVersion: Int = 0 // Version counter for conflict resolution (last-write-wins)
    var needsAppSelection: Bool = false // True if synced from another device but no local apps selected

    // MARK: - Trigger System (Schema Version 2)

    /// Schema version for migration and sync conflict detection
    /// Version 1: Legacy blockingStrategyId system
    /// Version 2: New start/stop trigger system
    var profileSchemaVersion: Int = 2

    /// Start triggers - serialized as JSON in SwiftData
    private var startTriggersData: Data?

    /// Stop conditions - serialized as JSON in SwiftData
    private var stopConditionsData: Data?

    /// Computed property for start triggers with JSON serialization
    var startTriggers: ProfileStartTriggers {
        get {
            guard let data = startTriggersData else { return ProfileStartTriggers() }
            do {
                return try JSONDecoder().decode(ProfileStartTriggers.self, from: data)
            } catch {
                Log.error("Failed to decode startTriggers: \(error.localizedDescription)", category: .sync)
                return ProfileStartTriggers()
            }
        }
        set {
            do {
                startTriggersData = try JSONEncoder().encode(newValue)
            } catch {
                Log.error("Failed to encode startTriggers: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    /// Computed property for stop conditions with JSON serialization
    var stopConditions: ProfileStopConditions {
        get {
            guard let data = stopConditionsData else { return ProfileStopConditions() }
            do {
                return try JSONDecoder().decode(ProfileStopConditions.self, from: data)
            } catch {
                Log.error("Failed to decode stopConditions: \(error.localizedDescription)", category: .sync)
                return ProfileStopConditions()
            }
        }
        set {
            do {
                stopConditionsData = try JSONEncoder().encode(newValue)
            } catch {
                Log.error("Failed to encode stopConditions: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    /// NFC tag ID required to start (when startTriggers.specificNFC = true)
    var startNFCTagId: String?

    /// QR code ID required to start (when startTriggers.specificQR = true)
    var startQRCodeId: String?

    /// NFC tag ID required to stop (when stopConditions.specificNFC = true)
    var stopNFCTagId: String?

    /// QR code ID required to stop (when stopConditions.specificQR = true)
    var stopQRCodeId: String?

    /// Start schedule - serialized as JSON in SwiftData
    private var startScheduleData: Data?

    /// Stop schedule - serialized as JSON in SwiftData
    private var stopScheduleData: Data?

    /// Computed property for start schedule with JSON serialization
    var startSchedule: ProfileScheduleTime? {
        get {
            guard let data = startScheduleData else { return nil }
            do {
                return try JSONDecoder().decode(ProfileScheduleTime.self, from: data)
            } catch {
                Log.error("Failed to decode startSchedule: \(error.localizedDescription)", category: .sync)
                return nil
            }
        }
        set {
            guard let value = newValue else {
                startScheduleData = nil
                return
            }
            do {
                startScheduleData = try JSONEncoder().encode(value)
            } catch {
                Log.error("Failed to encode startSchedule: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    /// Computed property for stop schedule with JSON serialization
    var stopSchedule: ProfileScheduleTime? {
        get {
            guard let data = stopScheduleData else { return nil }
            do {
                return try JSONDecoder().decode(ProfileScheduleTime.self, from: data)
            } catch {
                Log.error("Failed to decode stopSchedule: \(error.localizedDescription)", category: .sync)
                return nil
            }
        }
        set {
            guard let value = newValue else {
                stopScheduleData = nil
                return
            }
            do {
                stopScheduleData = try JSONEncoder().encode(value)
            } catch {
                Log.error("Failed to encode stopSchedule: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    @Relationship var sessions: [BlockedProfileSession] = []

    var activeScheduleTimerActivity: DeviceActivityName? {
        return DeviceActivityCenterUtil.getActiveScheduleTimerActivity(for: self)
    }

    var scheduleIsOutOfSync: Bool {
        let hasSchedule = (schedule?.isActive == true)
            || (startTriggers.schedule && startSchedule?.isActive == true)
        return hasSchedule
            && DeviceActivityCenterUtil.getActiveScheduleTimerActivity(for: self) == nil
    }

    init(
        id: UUID = UUID(),
        name: String,
        selectedActivity: FamilyActivitySelection = FamilyActivitySelection(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        blockingStrategyId: String = NFCBlockingStrategy.id,
        strategyData: Data? = nil,
        enableLiveActivity: Bool = false,
        reminderTimeInSeconds: UInt32? = nil,
        customReminderMessage: String? = nil,
        enableBreaks: Bool = false,
        breakTimeInMinutes: Int = 15,
        enableStrictMode: Bool = false,
        enableAllowMode: Bool = false,
        enableAllowModeDomains: Bool = false,
        enableSafariBlocking: Bool = true,
        order: Int = 0,
        domains: [String]? = nil,
        physicalUnblockNFCTagId: String? = nil,
        physicalUnblockQRCodeId: String? = nil,
        schedule: BlockedProfileSchedule? = nil,
        geofenceRule: ProfileGeofenceRule? = nil,
        disableBackgroundStops: Bool = false,
        preActivationReminderEnabled: Bool = false,
        preActivationReminderMinutes: UInt8 = 1,
        isManaged: Bool = false,
        managedByChildId: String? = nil,
        syncVersion: Int = 0,
        needsAppSelection: Bool = false
    ) {
        self.id = id
        self.name = name
        self.selectedActivity = selectedActivity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.blockingStrategyId = blockingStrategyId
        self.strategyData = strategyData
        self.order = order

        self.enableLiveActivity = enableLiveActivity
        self.reminderTimeInSeconds = reminderTimeInSeconds
        self.customReminderMessage = customReminderMessage
        self.enableBreaks = enableBreaks
        self.breakTimeInMinutes = breakTimeInMinutes
        self.enableStrictMode = enableStrictMode
        self.enableAllowMode = enableAllowMode
        self.enableAllowModeDomains = enableAllowModeDomains
        self.enableSafariBlocking = enableSafariBlocking
        self.domains = domains

        self.physicalUnblockNFCTagId = physicalUnblockNFCTagId
        self.physicalUnblockQRCodeId = physicalUnblockQRCodeId
        self.schedule = schedule
        self.geofenceRule = geofenceRule

        self.disableBackgroundStops = disableBackgroundStops
        self.preActivationReminderEnabled = preActivationReminderEnabled
        self.preActivationReminderMinutes = preActivationReminderMinutes
        self.isManaged = isManaged
        self.managedByChildId = managedByChildId
        self.syncVersion = syncVersion
        self.needsAppSelection = needsAppSelection
    }

    static func fetchProfiles(in context: ModelContext) throws
        -> [BlockedProfiles]
    {
        let descriptor = FetchDescriptor<BlockedProfiles>(
            sortBy: [
                SortDescriptor(\.order, order: .forward), SortDescriptor(\.createdAt, order: .reverse),
            ]
        )
        return try context.fetch(descriptor)
    }

    static func findProfile(byID id: UUID, in context: ModelContext) throws
        -> BlockedProfiles?
    {
        let descriptor = FetchDescriptor<BlockedProfiles>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    static func fetchMostRecentlyUpdatedProfile(in context: ModelContext) throws
        -> BlockedProfiles?
    {
        let descriptor = FetchDescriptor<BlockedProfiles>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first
    }

    static func updateProfile(
        _ profile: BlockedProfiles,
        in context: ModelContext,
        name: String? = nil,
        selection: FamilyActivitySelection? = nil,
        blockingStrategyId: String? = nil,
        strategyData: Data? = nil,
        enableLiveActivity: Bool? = nil,
        reminderTime: UInt32? = nil,
        customReminderMessage: String? = nil,
        enableBreaks: Bool? = nil,
        breakTimeInMinutes: Int? = nil,
        enableStrictMode: Bool? = nil,
        enableAllowMode: Bool? = nil,
        enableAllowModeDomains: Bool? = nil,
        enableSafariBlocking: Bool? = nil,
        order: Int? = nil,
        domains: [String]? = nil,
        physicalUnblockNFCTagId: String? = nil,
        physicalUnblockQRCodeId: String? = nil,
        schedule: BlockedProfileSchedule? = nil,
        geofenceRule: ProfileGeofenceRule? = nil,
        disableBackgroundStops: Bool? = nil,
        preActivationReminderEnabled: Bool? = nil,
        preActivationReminderMinutes: UInt8? = nil,
        isManaged: Bool? = nil,
        managedByChildId: String? = nil,
        syncVersion: Int? = nil,
        needsAppSelection: Bool? = nil
    ) throws -> BlockedProfiles {
        if let newName = name {
            profile.name = newName
        }

        if let newSelection = selection {
            profile.selectedActivity = newSelection
        }

        if let newStrategyId = blockingStrategyId {
            profile.blockingStrategyId = newStrategyId
        }

        if let newStrategyData = strategyData {
            profile.strategyData = newStrategyData
        }

        if let newEnableLiveActivity = enableLiveActivity {
            profile.enableLiveActivity = newEnableLiveActivity
        }

        if let newEnableBreaks = enableBreaks {
            profile.enableBreaks = newEnableBreaks
        }

        if let newBreakTimeInMinutes = breakTimeInMinutes {
            profile.breakTimeInMinutes = newBreakTimeInMinutes
        }

        if let newEnableStrictMode = enableStrictMode {
            profile.enableStrictMode = newEnableStrictMode
        }

        if let newEnableAllowMode = enableAllowMode {
            profile.enableAllowMode = newEnableAllowMode
        }

        if let newEnableAllowModeDomains = enableAllowModeDomains {
            profile.enableAllowModeDomains = newEnableAllowModeDomains
        }

        if let newEnableSafariBlocking = enableSafariBlocking {
            profile.enableSafariBlocking = newEnableSafariBlocking
        }

        if let newOrder = order {
            profile.order = newOrder
        }

        if let newDomains = domains {
            profile.domains = newDomains
        }

        if let newSchedule = schedule {
            profile.schedule = newSchedule
        }

        // geofenceRule can be set to nil to remove it
        profile.geofenceRule = geofenceRule

        if let newDisableBackgroundStops = disableBackgroundStops {
            profile.disableBackgroundStops = newDisableBackgroundStops
        }

        if let newPreActivationReminderEnabled = preActivationReminderEnabled {
            profile.preActivationReminderEnabled = newPreActivationReminderEnabled
        }

        if let newPreActivationReminderMinutes = preActivationReminderMinutes {
            profile.preActivationReminderMinutes = newPreActivationReminderMinutes
        }

        if let newIsManaged = isManaged {
            profile.isManaged = newIsManaged
        }

        // managedByChildId can be nil when removing assignment
        profile.managedByChildId = managedByChildId

        // Sync fields
        if let newSyncVersion = syncVersion {
            profile.syncVersion = newSyncVersion
        }
        if let newNeedsAppSelection = needsAppSelection {
            profile.needsAppSelection = newNeedsAppSelection
        }

        // Values can be nil when removed
        profile.physicalUnblockNFCTagId = physicalUnblockNFCTagId
        profile.physicalUnblockQRCodeId = physicalUnblockQRCodeId

        profile.reminderTimeInSeconds = reminderTime
        profile.customReminderMessage = customReminderMessage
        profile.updatedAt = Date()

        // Update the snapshot
        updateSnapshot(for: profile)

        try context.save()

        return profile
    }

    static func deleteProfile(
        _ profile: BlockedProfiles,
        in context: ModelContext
    ) throws {
        // First end any active sessions
        for session in profile.sessions {
            if session.endTime == nil {
                session.endSession()
            }
        }

        // Remove all sessions first
        for session in profile.sessions {
            context.delete(session)
        }

        // Delete the snapshot
        deleteSnapshot(for: profile)

        // Remove the schedule restrictions
        DeviceActivityCenterUtil.removeScheduleTimerActivities(for: profile)

        // Then delete the profile
        context.delete(profile)
        // Defer context saving as the reference to the profile might be used
    }

    static func getProfileDeepLink(_ profile: BlockedProfiles) -> String {
        return "https://family-foqos.app/profile/" + profile.id.uuidString
    }

    static func getSnapshot(for profile: BlockedProfiles) -> SharedData.ProfileSnapshot {
        return SharedData.ProfileSnapshot(
            id: profile.id,
            name: profile.name,
            selectedActivity: profile.selectedActivity,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt,
            blockingStrategyId: profile.blockingStrategyId,
            strategyData: profile.strategyData,
            order: profile.order,
            enableLiveActivity: profile.enableLiveActivity,
            reminderTimeInSeconds: profile.reminderTimeInSeconds,
            customReminderMessage: profile.customReminderMessage,
            enableBreaks: profile.enableBreaks,
            breakTimeInMinutes: profile.breakTimeInMinutes,
            enableStrictMode: profile.enableStrictMode,
            enableAllowMode: profile.enableAllowMode,
            enableAllowModeDomains: profile.enableAllowModeDomains,
            enableSafariBlocking: profile.enableSafariBlocking,
            preActivationReminderEnabled: profile.preActivationReminderEnabled,
            preActivationReminderMinutes: profile.preActivationReminderMinutes,
            domains: profile.domains,
            physicalUnblockNFCTagId: profile.physicalUnblockNFCTagId,
            physicalUnblockQRCodeId: profile.physicalUnblockQRCodeId,
            schedule: profile.schedule,
            startSchedule: profile.startSchedule,
            stopSchedule: profile.stopSchedule,
            startTriggersSchedule: profile.startTriggers.schedule,
            stopConditionsSchedule: profile.stopConditions.schedule,
            geofenceRule: profile.geofenceRule,
            disableBackgroundStops: profile.disableBackgroundStops,
            isManaged: profile.isManaged,
            managedByChildId: profile.managedByChildId,
            syncVersion: profile.syncVersion,
            needsAppSelection: profile.needsAppSelection
        )
    }

    /// Create a codable/equatable snapshot suitable for UserDefaults
    static func updateSnapshot(for profile: BlockedProfiles) {
        let snapshot = getSnapshot(for: profile)
        SharedData.setSnapshot(snapshot, for: profile.id.uuidString)
    }

    static func deleteSnapshot(for profile: BlockedProfiles) {
        SharedData.removeSnapshot(for: profile.id.uuidString)
    }

    static func reorderProfiles(
        _ profiles: [BlockedProfiles],
        in context: ModelContext
    ) throws {
        for (index, profile) in profiles.enumerated() {
            profile.order = index
        }
        try context.save()
    }

    static func getNextOrder(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<BlockedProfiles>(
            sortBy: [SortDescriptor(\.order, order: .reverse)]
        )
        guard let lastProfile = try? context.fetch(descriptor).first else {
            return 0
        }
        return lastProfile.order + 1
    }

    static func createProfile(
        in context: ModelContext,
        name: String,
        selection: FamilyActivitySelection = FamilyActivitySelection(),
        blockingStrategyId: String = NFCBlockingStrategy.id,
        strategyData: Data? = nil,
        enableLiveActivity: Bool = false,
        reminderTimeInSeconds: UInt32? = nil,
        customReminderMessage: String = "",
        enableBreaks: Bool = false,
        breakTimeInMinutes: Int = 15,
        enableStrictMode: Bool = false,
        enableAllowMode: Bool = false,
        enableAllowModeDomains: Bool = false,
        enableSafariBlocking: Bool = true,
        domains: [String]? = nil,
        physicalUnblockNFCTagId: String? = nil,
        physicalUnblockQRCodeId: String? = nil,
        schedule: BlockedProfileSchedule? = nil,
        geofenceRule: ProfileGeofenceRule? = nil,
        disableBackgroundStops: Bool = false,
        preActivationReminderEnabled: Bool = false,
        preActivationReminderMinutes: UInt8 = 1,
        isManaged: Bool = false,
        managedByChildId: String? = nil,
        syncVersion: Int = 0,
        needsAppSelection: Bool = false
    ) throws -> BlockedProfiles {
        let profileOrder = getNextOrder(in: context)

        let profile = BlockedProfiles(
            name: name,
            selectedActivity: selection,
            blockingStrategyId: blockingStrategyId,
            strategyData: strategyData,
            enableLiveActivity: enableLiveActivity,
            reminderTimeInSeconds: reminderTimeInSeconds,
            customReminderMessage: customReminderMessage,
            enableBreaks: enableBreaks,
            breakTimeInMinutes: breakTimeInMinutes,
            enableStrictMode: enableStrictMode,
            enableAllowMode: enableAllowMode,
            enableAllowModeDomains: enableAllowModeDomains,
            enableSafariBlocking: enableSafariBlocking,
            order: profileOrder,
            domains: domains,
            physicalUnblockNFCTagId: physicalUnblockNFCTagId,
            physicalUnblockQRCodeId: physicalUnblockQRCodeId,
            geofenceRule: geofenceRule,
            disableBackgroundStops: disableBackgroundStops,
            preActivationReminderEnabled: preActivationReminderEnabled,
            preActivationReminderMinutes: preActivationReminderMinutes,
            isManaged: isManaged,
            managedByChildId: managedByChildId,
            syncVersion: syncVersion,
            needsAppSelection: needsAppSelection
        )

        if let schedule = schedule {
            profile.schedule = schedule
        }

        // Create the snapshot so extensions can read it immediately
        updateSnapshot(for: profile)

        context.insert(profile)
        try context.save()
        return profile
    }

    static func cloneProfile(
        _ source: BlockedProfiles,
        in context: ModelContext,
        newName: String
    ) throws -> BlockedProfiles {
        let nextOrder = getNextOrder(in: context)
        let cloned = BlockedProfiles(
            name: newName,
            selectedActivity: source.selectedActivity,
            blockingStrategyId: source.blockingStrategyId ?? NFCBlockingStrategy.id,
            strategyData: source.strategyData,
            enableLiveActivity: source.enableLiveActivity,
            reminderTimeInSeconds: source.reminderTimeInSeconds,
            customReminderMessage: source.customReminderMessage,
            enableBreaks: source.enableBreaks,
            breakTimeInMinutes: source.breakTimeInMinutes,
            enableStrictMode: source.enableStrictMode,
            enableAllowMode: source.enableAllowMode,
            enableAllowModeDomains: source.enableAllowModeDomains,
            enableSafariBlocking: source.enableSafariBlocking,
            order: nextOrder,
            domains: source.domains,
            physicalUnblockNFCTagId: source.physicalUnblockNFCTagId,
            physicalUnblockQRCodeId: source.physicalUnblockQRCodeId,
            schedule: source.schedule,
            geofenceRule: source.geofenceRule,
            disableBackgroundStops: source.disableBackgroundStops,
            preActivationReminderEnabled: source.preActivationReminderEnabled,
            preActivationReminderMinutes: source.preActivationReminderMinutes,
            isManaged: source.isManaged,
            managedByChildId: source.managedByChildId,
            syncVersion: 0, // Reset sync version for cloned profile
            needsAppSelection: false // Cloned profile has app selection from source
        )

        context.insert(cloned)

        // Copy V2 trigger data
        cloned.startTriggers = source.startTriggers
        cloned.stopConditions = source.stopConditions
        cloned.startNFCTagId = source.startNFCTagId
        cloned.startQRCodeId = source.startQRCodeId
        cloned.stopNFCTagId = source.stopNFCTagId
        cloned.stopQRCodeId = source.stopQRCodeId
        cloned.startSchedule = source.startSchedule
        cloned.stopSchedule = source.stopSchedule

        try context.save()
        return cloned
    }

    static func addDomain(to profile: BlockedProfiles, context: ModelContext, domain: String) throws {
        guard let domains = profile.domains else {
            return
        }

        if domains.contains(domain) {
            return
        }

        let newDomains = domains + [domain]
        _ = try updateProfile(profile, in: context, domains: newDomains)
    }

    static func removeDomain(from profile: BlockedProfiles, context: ModelContext, domain: String)
        throws
    {
        guard let domains = profile.domains else {
            return
        }

        let newDomains = domains.filter { $0 != domain }
        _ = try updateProfile(profile, in: context, domains: newDomains)
    }
}

// MARK: - Migration

extension BlockedProfiles {
    /// Current schema version
    static let currentSchemaVersion = 2

    /// Whether this profile needs migration
    var needsMigration: Bool {
        profileSchemaVersion < Self.currentSchemaVersion
    }

    /// Whether this profile uses a newer schema version than this app supports.
    /// V3+ profiles should be read-only on this app version.
    var isNewerSchemaVersion: Bool {
        profileSchemaVersion > Self.currentSchemaVersion
    }

    /// Migrates to V2 if eligible (not already V2, no active session).
    /// Returns true if migration was performed.
    @discardableResult
    func migrateToV2IfEligible(hasActiveSession: Bool) -> Bool {
        guard needsMigration else { return false }
        guard !hasActiveSession else {
            Log.info("Deferring migration for '\(name)' — active session", category: .app)
            return false
        }
        migrateToV2IfNeeded()
        return !needsMigration
    }

    /// Migrates profile from V1 (blockingStrategyId) to V2 (triggers) if needed
    func migrateToV2IfNeeded() {
        guard profileSchemaVersion < 2 else { return }

        // Step 1: Migrate strategy to triggers
        let (migratedStart, migratedStop) = TriggerMigration.migrateFromStrategy(
            blockingStrategyId
        )
        startTriggers = migratedStart
        var stop = migratedStop

        // Step 2: Migrate physical unlock
        if physicalUnblockNFCTagId != nil || physicalUnblockQRCodeId != nil {
            let (updatedStop, tagId) = TriggerMigration.migratePhysicalUnlock(
                stopConditions: stop,
                physicalUnblockNFCTagId: physicalUnblockNFCTagId,
                physicalUnblockQRCodeId: physicalUnblockQRCodeId
            )
            stop = updatedStop
            if physicalUnblockNFCTagId != nil {
                stopNFCTagId = tagId
            } else {
                stopQRCodeId = tagId
            }
        }
        stopConditions = stop

        // Step 3: Migrate schedule
        let (start, stopSched) = TriggerMigration.migrateSchedule(schedule)
        startSchedule = start
        stopSchedule = stopSched

        // Enable schedule trigger if schedule was active
        if schedule?.isActive == true {
            var triggers = startTriggers
            triggers.schedule = true
            startTriggers = triggers

            var conditions = stopConditions
            conditions.schedule = true
            stopConditions = conditions
        }

        // Step 4: Verify encoding succeeded before marking as migrated
        // If any Data field is nil after setting, encoding failed silently
        guard startTriggersData != nil, stopConditionsData != nil else {
            Log.error(
                "Migration encoding failed for '\(name)' — staying at V1",
                category: .app
            )
            return
        }

        // Step 5: Mark as migrated (only if all data encoded successfully)
        profileSchemaVersion = 2
    }

    /// Best-match strategy ID for backwards compatibility with older app versions.
    /// Maps new triggers to closest legacy strategy.
    var compatibilityStrategyId: String {
        let start = startTriggers
        let stop = stopConditions

        if start.anyNFC && stop.sameNFC {
            return "NFCBlockingStrategy"
        }
        if start.manual && stop.anyNFC && stop.timer {
            return "NFCTimerBlockingStrategy"
        }
        if start.manual && stop.anyNFC {
            return "NFCManualBlockingStrategy"
        }
        if start.anyQR && stop.sameQR {
            return "QRCodeBlockingStrategy"
        }
        if start.manual && stop.anyQR && stop.timer {
            return "QRTimerBlockingStrategy"
        }
        if start.manual && stop.anyQR {
            return "QRManualBlockingStrategy"
        }
        if start.manual && stop.timer && !stop.anyNFC && !stop.anyQR {
            return "ShortcutTimerBlockingStrategy"
        }

        // Default to manual
        return "ManualBlockingStrategy"
    }

    /// Updates blockingStrategyId for backwards compatibility with older app versions
    func updateCompatibilityStrategyId() {
        blockingStrategyId = compatibilityStrategyId
    }
}
