import Foundation

/// Represents the operating mode of the Foqos app
enum AppMode: String, Codable, CaseIterable {
    /// Self-control mode - user manages their own Screen Time (current behavior)
    case individual

    /// Parent mode - user creates and manages policies for children
    case parent

    /// Child mode - user receives and is subject to parent-pushed policies
    case child

    var displayName: String {
        switch self {
        case .individual:
            return "For Myself"
        case .parent:
            return "As a Parent"
        case .child:
            return "As a Child"
        }
    }

    var description: String {
        switch self {
        case .individual:
            return "Control your own screen time. Access Family Controls from Settings."
        case .parent:
            return "Manage your children's screen time. Can also use personal profiles."
        case .child:
            return "Receive screen time policies from your parent"
        }
    }

    var iconName: String {
        switch self {
        case .individual:
            return "person.fill"
        case .parent:
            return "person.2.fill"
        case .child:
            return "face.smiling.fill"
        }
    }
}

/// Manages the current app mode with persistence
@MainActor
class AppModeManager: ObservableObject {
    static let shared = AppModeManager()

    private let userDefaults = UserDefaults.standard
    private let modeKey = "family_foqos_app_mode"
    private let hasSelectedModeKey = "family_foqos_has_selected_mode"

    @Published var currentMode: AppMode {
        didSet {
            userDefaults.set(currentMode.rawValue, forKey: modeKey)
        }
    }

    @Published var hasSelectedMode: Bool {
        didSet {
            userDefaults.set(hasSelectedMode, forKey: hasSelectedModeKey)
        }
    }

    private init() {
        // Load saved mode or default to individual
        if let savedMode = userDefaults.string(forKey: modeKey),
           let mode = AppMode(rawValue: savedMode) {
            self.currentMode = mode
        } else {
            self.currentMode = .individual
        }

        self.hasSelectedMode = userDefaults.bool(forKey: hasSelectedModeKey)
    }

    func selectMode(_ mode: AppMode) {
        currentMode = mode
        hasSelectedMode = true
    }

    /// Returns true if the current mode allows creating/editing personal profiles
    var canCreateProfiles: Bool {
        currentMode == .individual || currentMode == .parent
    }

    /// Returns true if the current mode is subject to parent policies
    var isSubjectToParentPolicies: Bool {
        currentMode == .child
    }

    /// Returns true if the current mode can create policies for others
    var canCreateFamilyPolicies: Bool {
        currentMode == .parent
    }
}
