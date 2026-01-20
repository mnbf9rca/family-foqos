import CloudKit
import Foundation

/// Standard app category identifiers used by Apple's Screen Time
/// These can be synced across devices (unlike FamilyActivitySelection tokens)
enum AppCategoryIdentifier: String, CaseIterable, Codable, Identifiable {
    case socialNetworking = "com.apple.AppCategory-SocialNetworking"
    case games = "com.apple.AppCategory-Games"
    case entertainment = "com.apple.AppCategory-Entertainment"
    case productivity = "com.apple.AppCategory-Productivity"
    case education = "com.apple.AppCategory-Education"
    case creativityPhotosVideo = "com.apple.AppCategory-Creativity"
    case utilities = "com.apple.AppCategory-Utilities"
    case healthFitness = "com.apple.AppCategory-HealthAndFitness"
    case news = "com.apple.AppCategory-News"
    case finance = "com.apple.AppCategory-Finance"
    case shopping = "com.apple.AppCategory-Shopping"
    case travel = "com.apple.AppCategory-Travel"
    case foodDrink = "com.apple.AppCategory-FoodAndDrink"
    case sports = "com.apple.AppCategory-Sports"
    case music = "com.apple.AppCategory-Music"
    case photoVideo = "com.apple.AppCategory-PhotoAndVideo"
    case navigation = "com.apple.AppCategory-Navigation"
    case lifestyle = "com.apple.AppCategory-Lifestyle"
    case books = "com.apple.AppCategory-Books"
    case business = "com.apple.AppCategory-Business"
    case weather = "com.apple.AppCategory-Weather"
    case reference = "com.apple.AppCategory-Reference"
    case medical = "com.apple.AppCategory-Medical"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .socialNetworking: return "Social Networking"
        case .games: return "Games"
        case .entertainment: return "Entertainment"
        case .productivity: return "Productivity"
        case .education: return "Education"
        case .creativityPhotosVideo: return "Creativity"
        case .utilities: return "Utilities"
        case .healthFitness: return "Health & Fitness"
        case .news: return "News"
        case .finance: return "Finance"
        case .shopping: return "Shopping"
        case .travel: return "Travel"
        case .foodDrink: return "Food & Drink"
        case .sports: return "Sports"
        case .music: return "Music"
        case .photoVideo: return "Photo & Video"
        case .navigation: return "Navigation"
        case .lifestyle: return "Lifestyle"
        case .books: return "Books"
        case .business: return "Business"
        case .weather: return "Weather"
        case .reference: return "Reference"
        case .medical: return "Medical"
        }
    }

    var iconName: String {
        switch self {
        case .socialNetworking: return "bubble.left.and.bubble.right.fill"
        case .games: return "gamecontroller.fill"
        case .entertainment: return "tv.fill"
        case .productivity: return "doc.text.fill"
        case .education: return "graduationcap.fill"
        case .creativityPhotosVideo: return "paintbrush.fill"
        case .utilities: return "wrench.and.screwdriver.fill"
        case .healthFitness: return "heart.fill"
        case .news: return "newspaper.fill"
        case .finance: return "dollarsign.circle.fill"
        case .shopping: return "cart.fill"
        case .travel: return "airplane"
        case .foodDrink: return "fork.knife"
        case .sports: return "sportscourt.fill"
        case .music: return "music.note"
        case .photoVideo: return "camera.fill"
        case .navigation: return "map.fill"
        case .lifestyle: return "leaf.fill"
        case .books: return "book.fill"
        case .business: return "briefcase.fill"
        case .weather: return "cloud.sun.fill"
        case .reference: return "text.book.closed.fill"
        case .medical: return "cross.case.fill"
        }
    }
}

/// A policy created by a parent and synced to a child's device via CloudKit
struct FamilyPolicy: Codable, Identifiable, Equatable {
    var id: UUID
    var parentUserRecordName: String  // CKRecord.ID.recordName of the parent
    var assignedChildIds: [String]    // IDs of EnrolledChild records this policy applies to (empty = all children)

    // Basic info
    var name: String
    var createdAt: Date
    var updatedAt: Date

    // Restrictions - using category identifiers (not device-specific tokens)
    var blockedCategoryIdentifiers: [String]
    var blockedDomains: [String]

    // NFC unlock configuration
    var nfcUnlockEnabled: Bool
    var nfcTagIdentifier: String?  // The specific tag that can unlock this policy
    var unlockDurationMinutes: Int  // How long the unlock lasts (e.g., 15)

    // Schedule (optional daily restriction windows)
    var scheduleEnabled: Bool
    var schedule: BlockedProfileSchedule?

    // Enforcement flags
    var isActive: Bool
    var denyAppRemoval: Bool  // Strict mode - prevent uninstalling apps
    var allowChildEmergencyUnblock: Bool  // If true, child can use emergency unblock

    init(
        id: UUID = UUID(),
        parentUserRecordName: String,
        assignedChildIds: [String] = [],  // Empty = applies to all children
        name: String,
        blockedCategoryIdentifiers: [String] = [],
        blockedDomains: [String] = [],
        nfcUnlockEnabled: Bool = true,
        nfcTagIdentifier: String? = nil,
        unlockDurationMinutes: Int = 15,
        scheduleEnabled: Bool = false,
        schedule: BlockedProfileSchedule? = nil,
        isActive: Bool = true,
        denyAppRemoval: Bool = false,
        allowChildEmergencyUnblock: Bool = false
    ) {
        self.id = id
        self.parentUserRecordName = parentUserRecordName
        self.assignedChildIds = assignedChildIds
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.blockedCategoryIdentifiers = blockedCategoryIdentifiers
        self.blockedDomains = blockedDomains
        self.nfcUnlockEnabled = nfcUnlockEnabled
        self.nfcTagIdentifier = nfcTagIdentifier
        self.unlockDurationMinutes = unlockDurationMinutes
        self.scheduleEnabled = scheduleEnabled
        self.schedule = schedule
        self.isActive = isActive
        self.denyAppRemoval = denyAppRemoval
        self.allowChildEmergencyUnblock = allowChildEmergencyUnblock
    }

    // MARK: - Child Assignment Helpers

    /// Check if this policy applies to a specific child
    func appliesTo(childId: String) -> Bool {
        // Empty array means applies to all children
        assignedChildIds.isEmpty || assignedChildIds.contains(childId)
    }

    /// Check if this policy applies to all children
    var appliesToAllChildren: Bool {
        assignedChildIds.isEmpty
    }

    // MARK: - Computed Properties

    var blockedCategories: [AppCategoryIdentifier] {
        blockedCategoryIdentifiers.compactMap { AppCategoryIdentifier(rawValue: $0) }
    }

    var hasRestrictions: Bool {
        !blockedCategoryIdentifiers.isEmpty || !blockedDomains.isEmpty
    }

    var summaryText: String {
        var parts: [String] = []

        if !blockedCategoryIdentifiers.isEmpty {
            parts.append("\(blockedCategoryIdentifiers.count) categories")
        }
        if !blockedDomains.isEmpty {
            parts.append("\(blockedDomains.count) domains")
        }
        if nfcUnlockEnabled {
            parts.append("NFC unlock (\(unlockDurationMinutes)min)")
        }

        return parts.isEmpty ? "No restrictions" : parts.joined(separator: " · ")
    }

    // MARK: - Mutation

    mutating func markUpdated() {
        updatedAt = Date()
    }
}

// MARK: - CloudKit Record Conversion

extension FamilyPolicy {
    static let recordType = "FamilyPolicy"

    // CKRecord field keys
    private enum RecordKey {
        static let id = "id"
        static let parentUserRecordName = "parentUserRecordName"
        static let assignedChildIds = "assignedChildIds"
        static let name = "name"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
        static let blockedCategoryIdentifiers = "blockedCategoryIdentifiers"
        static let blockedDomains = "blockedDomains"
        static let nfcUnlockEnabled = "nfcUnlockEnabled"
        static let nfcTagIdentifier = "nfcTagIdentifier"
        static let unlockDurationMinutes = "unlockDurationMinutes"
        static let scheduleEnabled = "scheduleEnabled"
        static let scheduleData = "scheduleData"
        static let isActive = "isActive"
        static let denyAppRemoval = "denyAppRemoval"
        static let allowChildEmergencyUnblock = "allowChildEmergencyUnblock"
    }

    /// Create a FamilyPolicy from a CKRecord
    init?(from record: CKRecord) {
        guard record.recordType == FamilyPolicy.recordType,
              let idString = record[RecordKey.id] as? String,
              let id = UUID(uuidString: idString),
              let parentUserRecordName = record[RecordKey.parentUserRecordName] as? String,
              let name = record[RecordKey.name] as? String,
              let createdAt = record[RecordKey.createdAt] as? Date,
              let updatedAt = record[RecordKey.updatedAt] as? Date
        else {
            return nil
        }

        self.id = id
        self.parentUserRecordName = parentUserRecordName
        self.assignedChildIds = record[RecordKey.assignedChildIds] as? [String] ?? []
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt

        // Arrays
        self.blockedCategoryIdentifiers = record[RecordKey.blockedCategoryIdentifiers] as? [String] ?? []
        self.blockedDomains = record[RecordKey.blockedDomains] as? [String] ?? []

        // NFC configuration
        self.nfcUnlockEnabled = (record[RecordKey.nfcUnlockEnabled] as? Int ?? 1) == 1
        self.nfcTagIdentifier = record[RecordKey.nfcTagIdentifier] as? String
        self.unlockDurationMinutes = record[RecordKey.unlockDurationMinutes] as? Int ?? 15

        // Schedule
        self.scheduleEnabled = (record[RecordKey.scheduleEnabled] as? Int ?? 0) == 1
        if let scheduleData = record[RecordKey.scheduleData] as? Data {
            self.schedule = try? JSONDecoder().decode(BlockedProfileSchedule.self, from: scheduleData)
        } else {
            self.schedule = nil
        }

        // Flags
        self.isActive = (record[RecordKey.isActive] as? Int ?? 1) == 1
        self.denyAppRemoval = (record[RecordKey.denyAppRemoval] as? Int ?? 0) == 1
        self.allowChildEmergencyUnblock = (record[RecordKey.allowChildEmergencyUnblock] as? Int ?? 0) == 1
    }

    /// Convert to a CKRecord for saving to CloudKit
    func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: FamilyPolicy.recordType, recordID: recordID)

        record[RecordKey.id] = id.uuidString
        record[RecordKey.parentUserRecordName] = parentUserRecordName
        record[RecordKey.name] = name
        record[RecordKey.createdAt] = createdAt
        record[RecordKey.updatedAt] = updatedAt

        // Set parent reference to FamilyRoot for share hierarchy
        let familyRootID = CKRecord.ID(recordName: "FamilyRoot", zoneID: zoneID)
        record.parent = CKRecord.Reference(recordID: familyRootID, action: .none)

        // Only set array fields if they have values (CloudKit can't infer type from empty arrays)
        if !assignedChildIds.isEmpty {
            record[RecordKey.assignedChildIds] = assignedChildIds
        }
        if !blockedCategoryIdentifiers.isEmpty {
            record[RecordKey.blockedCategoryIdentifiers] = blockedCategoryIdentifiers
        }
        if !blockedDomains.isEmpty {
            record[RecordKey.blockedDomains] = blockedDomains
        }

        record[RecordKey.nfcUnlockEnabled] = nfcUnlockEnabled ? 1 : 0
        record[RecordKey.nfcTagIdentifier] = nfcTagIdentifier
        record[RecordKey.unlockDurationMinutes] = unlockDurationMinutes

        record[RecordKey.scheduleEnabled] = scheduleEnabled ? 1 : 0
        if let schedule = schedule,
           let scheduleData = try? JSONEncoder().encode(schedule) {
            record[RecordKey.scheduleData] = scheduleData
        }

        record[RecordKey.isActive] = isActive ? 1 : 0
        record[RecordKey.denyAppRemoval] = denyAppRemoval ? 1 : 0
        record[RecordKey.allowChildEmergencyUnblock] = allowChildEmergencyUnblock ? 1 : 0

        return record
    }

    /// Update an existing CKRecord with this policy's values
    func updateCKRecord(_ record: CKRecord) {
        record[RecordKey.name] = name
        record[RecordKey.updatedAt] = updatedAt

        // Only set array fields if they have values (CloudKit can't infer type from empty arrays on new fields)
        if !assignedChildIds.isEmpty {
            record[RecordKey.assignedChildIds] = assignedChildIds
        }
        if !blockedCategoryIdentifiers.isEmpty {
            record[RecordKey.blockedCategoryIdentifiers] = blockedCategoryIdentifiers
        }
        if !blockedDomains.isEmpty {
            record[RecordKey.blockedDomains] = blockedDomains
        }

        record[RecordKey.nfcUnlockEnabled] = nfcUnlockEnabled ? 1 : 0
        record[RecordKey.nfcTagIdentifier] = nfcTagIdentifier
        record[RecordKey.unlockDurationMinutes] = unlockDurationMinutes

        record[RecordKey.scheduleEnabled] = scheduleEnabled ? 1 : 0
        if let schedule = schedule,
           let scheduleData = try? JSONEncoder().encode(schedule) {
            record[RecordKey.scheduleData] = scheduleData
        }

        record[RecordKey.isActive] = isActive ? 1 : 0
        record[RecordKey.denyAppRemoval] = denyAppRemoval ? 1 : 0
        record[RecordKey.allowChildEmergencyUnblock] = allowChildEmergencyUnblock ? 1 : 0
    }
}

// MARK: - NFC Unlock Session

/// Represents an active NFC unlock session for a FamilyPolicy
struct NFCUnlockSession: Codable, Identifiable, Equatable {
    var id: UUID
    var policyId: UUID
    var policyName: String
    var startTime: Date
    var durationMinutes: Int
    var tagIdentifier: String

    var endTime: Date {
        startTime.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    var remainingTime: TimeInterval {
        max(0, endTime.timeIntervalSince(Date()))
    }

    var isExpired: Bool {
        Date() >= endTime
    }

    var remainingTimeFormatted: String {
        let remaining = remainingTime
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    init(
        id: UUID = UUID(),
        policyId: UUID,
        policyName: String,
        durationMinutes: Int,
        tagIdentifier: String
    ) {
        self.id = id
        self.policyId = policyId
        self.policyName = policyName
        self.startTime = Date()
        self.durationMinutes = durationMinutes
        self.tagIdentifier = tagIdentifier
    }
}
