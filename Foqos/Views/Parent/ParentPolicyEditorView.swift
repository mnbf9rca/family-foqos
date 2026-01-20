import SwiftUI

/// View for creating and editing family policies (parent operation)
struct ParentPolicyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cloudKitManager = CloudKitManager.shared

    // Editing state
    let existingPolicy: FamilyPolicy?
    let onSave: (FamilyPolicy) -> Void

    // Form state
    @State private var name: String = ""
    @State private var selectedCategories: Set<AppCategoryIdentifier> = []
    @State private var blockedDomains: [String] = []
    @State private var newDomain: String = ""

    @State private var nfcUnlockEnabled: Bool = true
    @State private var unlockDurationMinutes: Int = 15

    @State private var scheduleEnabled: Bool = false
    @State private var selectedDays: [Weekday] = []
    @State private var startHour: Int = 8
    @State private var startMinute: Int = 0
    @State private var endHour: Int = 20
    @State private var endMinute: Int = 0

    @State private var denyAppRemoval: Bool = false
    @State private var allowChildEmergencyUnblock: Bool = false
    @State private var isActive: Bool = true

    // Child assignment
    @State private var applyToAllChildren: Bool = true
    @State private var selectedChildIds: Set<String> = []

    @State private var isSaving = false
    @State private var showError = false
    @State private var errorMessage = ""

    init(policy: FamilyPolicy?, onSave: @escaping (FamilyPolicy) -> Void) {
        self.existingPolicy = policy
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                // iCloud status warning if not ready
                if !cloudKitManager.isSignedIn || cloudKitManager.currentUserRecordID == nil {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.icloud.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud Not Ready")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Please ensure you're signed in to iCloud to save policies.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Basic Info
                Section("Policy Name") {
                    TextField("e.g., Homework Time", text: $name)
                }

                // Categories to block
                Section {
                    NavigationLink {
                        CategorySelectionView(selectedCategories: $selectedCategories)
                    } label: {
                        HStack {
                            Text("Blocked Categories")
                            Spacer()
                            Text("\(selectedCategories.count) selected")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("App Restrictions")
                } footer: {
                    Text("Select app categories to block. These will be blocked on your child's device.")
                }

                // Domains to block
                Section {
                    ForEach(blockedDomains, id: \.self) { domain in
                        HStack {
                            Text(domain)
                            Spacer()
                            Button {
                                blockedDomains.removeAll { $0 == domain }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    HStack {
                        TextField("Add domain (e.g., tiktok.com)", text: $newDomain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            addDomain()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newDomain.isEmpty)
                    }
                } header: {
                    Text("Website Restrictions")
                }

                // NFC Unlock
                Section {
                    Toggle("Enable NFC Unlock", isOn: $nfcUnlockEnabled)

                    if nfcUnlockEnabled {
                        Stepper(
                            "Unlock Duration: \(unlockDurationMinutes) min",
                            value: $unlockDurationMinutes,
                            in: 5...120,
                            step: 5
                        )
                    }
                } header: {
                    Text("NFC Unlock")
                } footer: {
                    Text("When enabled, your child can scan an NFC tag to temporarily unlock blocked apps for the specified duration.")
                }

                // Schedule
                Section {
                    Toggle("Enable Schedule", isOn: $scheduleEnabled)

                    if scheduleEnabled {
                        NavigationLink {
                            ScheduleEditorView(
                                selectedDays: $selectedDays,
                                startHour: $startHour,
                                startMinute: $startMinute,
                                endHour: $endHour,
                                endMinute: $endMinute
                            )
                        } label: {
                            HStack {
                                Text("Schedule")
                                Spacer()
                                if !selectedDays.isEmpty {
                                    Text(scheduleDescription)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Set specific times when the restrictions are active.")
                }

                // Advanced Options
                Section {
                    Toggle("Prevent App Removal", isOn: $denyAppRemoval)
                    Toggle("Allow Emergency Unblock", isOn: $allowChildEmergencyUnblock)
                    Toggle("Policy Active", isOn: $isActive)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Prevent App Removal stops your child from uninstalling apps. Allow Emergency Unblock lets your child use their limited emergency unblocks on this policy.")
                }

                // Child Assignment
                Section {
                    Toggle("Apply to All Children", isOn: $applyToAllChildren)

                    if !applyToAllChildren {
                        if cloudKitManager.enrolledChildren.isEmpty {
                            HStack {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                Text("No children enrolled yet. Add children from the dashboard first.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            ForEach(cloudKitManager.enrolledChildren) { child in
                                Button {
                                    toggleChildSelection(child)
                                } label: {
                                    HStack {
                                        Image(systemName: "person.fill")
                                            .foregroundColor(.accentColor)
                                        Text(child.displayName)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if selectedChildIds.contains(child.userRecordName) {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Apply To")
                } footer: {
                    if applyToAllChildren {
                        Text("This policy will apply to all enrolled children, including any added in the future.")
                    } else {
                        Text("Select which children this policy should apply to.")
                    }
                }
            }
            .navigationTitle(existingPolicy == nil ? "New Policy" : "Edit Policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        savePolicy()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .onAppear {
                loadExistingPolicy()
                // Ensure iCloud is ready
                Task {
                    await cloudKitManager.checkAccountStatus()
                    print("ParentPolicyEditorView: onAppear - isSignedIn: \(cloudKitManager.isSignedIn), userRecordID: \(String(describing: cloudKitManager.currentUserRecordID))")
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Computed Properties

    private var scheduleDescription: String {
        guard !selectedDays.isEmpty else { return "Not set" }

        let days = selectedDays
            .sorted { $0.rawValue < $1.rawValue }
            .map { $0.shortLabel }
            .joined(separator: " ")

        return "\(days) \(formatTime(startHour, startMinute))-\(formatTime(endHour, endMinute))"
    }

    private func formatTime(_ hour: Int, _ minute: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return "\(h):\(String(format: "%02d", minute))\(ampm)"
    }

    // MARK: - Actions

    private func loadExistingPolicy() {
        guard let policy = existingPolicy else { return }

        name = policy.name
        selectedCategories = Set(policy.blockedCategories)
        blockedDomains = policy.blockedDomains
        nfcUnlockEnabled = policy.nfcUnlockEnabled
        unlockDurationMinutes = policy.unlockDurationMinutes
        denyAppRemoval = policy.denyAppRemoval
        allowChildEmergencyUnblock = policy.allowChildEmergencyUnblock
        isActive = policy.isActive

        // Load child assignment
        applyToAllChildren = policy.appliesToAllChildren
        selectedChildIds = Set(policy.assignedChildIds)

        if let schedule = policy.schedule {
            scheduleEnabled = policy.scheduleEnabled
            selectedDays = schedule.days
            startHour = schedule.startHour
            startMinute = schedule.startMinute
            endHour = schedule.endHour
            endMinute = schedule.endMinute
        }
    }

    private func toggleChildSelection(_ child: EnrolledChild) {
        // Use userRecordName so child device can filter by their iCloud record
        let childId = child.userRecordName
        if selectedChildIds.contains(childId) {
            selectedChildIds.remove(childId)
        } else {
            selectedChildIds.insert(childId)
        }
    }

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, !blockedDomains.contains(domain) else { return }
        blockedDomains.append(domain)
        newDomain = ""
    }

    private func savePolicy() {
        print("ParentPolicyEditorView: savePolicy() called")
        print("ParentPolicyEditorView: isSignedIn = \(cloudKitManager.isSignedIn)")
        print("ParentPolicyEditorView: currentUserRecordID = \(String(describing: cloudKitManager.currentUserRecordID))")

        guard let userRecordID = cloudKitManager.currentUserRecordID else {
            errorMessage = "Not signed in to iCloud. Please ensure you're signed in to iCloud in Settings and try again."
            showError = true
            print("ParentPolicyEditorView: ERROR - currentUserRecordID is nil, cannot save")
            return
        }

        isSaving = true
        print("ParentPolicyEditorView: Creating policy with parent record: \(userRecordID.recordName)")

        var policy = existingPolicy ?? FamilyPolicy(
            parentUserRecordName: userRecordID.recordName,
            name: name
        )

        policy.name = name
        policy.blockedCategoryIdentifiers = selectedCategories.map { $0.rawValue }
        policy.blockedDomains = blockedDomains
        policy.nfcUnlockEnabled = nfcUnlockEnabled
        policy.unlockDurationMinutes = unlockDurationMinutes
        policy.denyAppRemoval = denyAppRemoval
        policy.allowChildEmergencyUnblock = allowChildEmergencyUnblock
        policy.isActive = isActive
        policy.scheduleEnabled = scheduleEnabled

        // Child assignment
        policy.assignedChildIds = applyToAllChildren ? [] : Array(selectedChildIds)

        if scheduleEnabled && !selectedDays.isEmpty {
            policy.schedule = BlockedProfileSchedule(
                days: selectedDays,
                startHour: startHour,
                startMinute: startMinute,
                endHour: endHour,
                endMinute: endMinute
            )
        } else {
            policy.schedule = nil
        }

        policy.markUpdated()

        print("ParentPolicyEditorView: Policy created locally, calling onSave callback")
        print("ParentPolicyEditorView: Policy ID: \(policy.id), Name: \(policy.name)")
        onSave(policy)
        dismiss()
    }
}

// MARK: - Category Selection View

struct CategorySelectionView: View {
    @Binding var selectedCategories: Set<AppCategoryIdentifier>

    var body: some View {
        List {
            ForEach(AppCategoryIdentifier.allCases) { category in
                Button {
                    toggleCategory(category)
                } label: {
                    HStack {
                        Image(systemName: category.iconName)
                            .foregroundColor(.accentColor)
                            .frame(width: 30)

                        Text(category.displayName)
                            .foregroundColor(.primary)

                        Spacer()

                        if selectedCategories.contains(category) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Select Categories")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Select All") {
                        selectedCategories = Set(AppCategoryIdentifier.allCases)
                    }
                    Button("Clear All") {
                        selectedCategories.removeAll()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func toggleCategory(_ category: AppCategoryIdentifier) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
    }
}

// MARK: - Schedule Editor View

struct ScheduleEditorView: View {
    @Binding var selectedDays: [Weekday]
    @Binding var startHour: Int
    @Binding var startMinute: Int
    @Binding var endHour: Int
    @Binding var endMinute: Int

    @State private var startTime: Date = Date()
    @State private var endTime: Date = Date()

    var body: some View {
        Form {
            Section("Days") {
                ForEach(Weekday.allCases, id: \.self) { day in
                    Button {
                        toggleDay(day)
                    } label: {
                        HStack {
                            Text(day.name)
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedDays.contains(day) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }

            Section("Time Range") {
                DatePicker(
                    "Start Time",
                    selection: $startTime,
                    displayedComponents: .hourAndMinute
                )
                .onChange(of: startTime) { _, newValue in
                    let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                    startHour = components.hour ?? 0
                    startMinute = components.minute ?? 0
                }

                DatePicker(
                    "End Time",
                    selection: $endTime,
                    displayedComponents: .hourAndMinute
                )
                .onChange(of: endTime) { _, newValue in
                    let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                    endHour = components.hour ?? 0
                    endMinute = components.minute ?? 0
                }
            }

            Section {
                Button("Weekdays Only") {
                    selectedDays = [.monday, .tuesday, .wednesday, .thursday, .friday]
                }
                Button("Weekends Only") {
                    selectedDays = [.saturday, .sunday]
                }
                Button("Every Day") {
                    selectedDays = Weekday.allCases
                }
            }
        }
        .navigationTitle("Schedule")
        .onAppear {
            // Initialize time pickers from binding values
            var calendar = Calendar.current
            calendar.timeZone = TimeZone.current

            var startComponents = DateComponents()
            startComponents.hour = startHour
            startComponents.minute = startMinute
            if let date = calendar.date(from: startComponents) {
                startTime = date
            }

            var endComponents = DateComponents()
            endComponents.hour = endHour
            endComponents.minute = endMinute
            if let date = calendar.date(from: endComponents) {
                endTime = date
            }
        }
    }

    private func toggleDay(_ day: Weekday) {
        if let index = selectedDays.firstIndex(of: day) {
            selectedDays.remove(at: index)
        } else {
            selectedDays.append(day)
        }
    }
}

#Preview {
    ParentPolicyEditorView(policy: nil) { _ in }
}
