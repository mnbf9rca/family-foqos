@testable import FamilyFoqos
import XCTest

final class PreActivationReminderTests: XCTestCase {
    // MARK: - Notification Identifier Tests

    func testPreActivationReminderIdentifier_generatesCorrectFormat() {
        let profileId = UUID()
        let identifier = TimersUtil.preActivationReminderIdentifier(for: profileId)

        XCTAssertEqual(identifier, "pre-activation-reminder-\(profileId.uuidString)")
    }

    func testPreActivationReminderIdentifier_uniquePerProfile() {
        let profileId1 = UUID()
        let profileId2 = UUID()

        let identifier1 = TimersUtil.preActivationReminderIdentifier(for: profileId1)
        let identifier2 = TimersUtil.preActivationReminderIdentifier(for: profileId2)

        XCTAssertNotEqual(identifier1, identifier2)
    }

    func testPreActivationReminderIdentifier_hasCorrectPrefix() {
        let profileId = UUID()
        let identifier = TimersUtil.preActivationReminderIdentifier(for: profileId)

        XCTAssertTrue(identifier.hasPrefix(TimersUtil.preActivationReminderPrefix))
    }

    func testReminderTimeCalculation() {
        // Test that reminder time is correctly calculated as (start time - minutes)
        let calendar = Calendar.current
        let now = Date()

        guard
            let scheduledStart = calendar.date(
                bySettingHour: 10,
                minute: 0,
                second: 0,
                of: now
            )
        else {
            XCTFail("Could not create scheduled start time")
            return
        }

        let reminderMinutes = 5
        guard
            let reminderTime = calendar.date(
                byAdding: .minute,
                value: -reminderMinutes,
                to: scheduledStart
            )
        else {
            XCTFail("Could not calculate reminder time")
            return
        }

        // The reminder time should be 5 minutes before the scheduled start
        let expectedHour = 9
        let expectedMinute = 55

        let reminderHour = calendar.component(.hour, from: reminderTime)
        let reminderMinute = calendar.component(.minute, from: reminderTime)

        XCTAssertEqual(reminderHour, expectedHour)
        XCTAssertEqual(reminderMinute, expectedMinute)
    }
}
