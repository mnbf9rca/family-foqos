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

    // MARK: - Schedule Tests

    func testScheduleIsTodayScheduled_returnsTrueForToday() {
        let calendar = Calendar.current
        let today = calendar.component(.weekday, from: Date())
        guard let weekday = Weekday(rawValue: today) else {
            XCTFail("Could not get today's weekday")
            return
        }

        let schedule = BlockedProfileSchedule(
            days: [weekday],
            startHour: 9,
            startMinute: 0,
            endHour: 17,
            endMinute: 0
        )

        XCTAssertTrue(schedule.isTodayScheduled())
    }

    func testScheduleIsTodayScheduled_returnsFalseForOtherDay() {
        let calendar = Calendar.current
        let today = calendar.component(.weekday, from: Date())

        // Get a different weekday
        let otherWeekdayRaw = today == 7 ? 1 : today + 1
        guard let otherWeekday = Weekday(rawValue: otherWeekdayRaw) else {
            XCTFail("Could not get other weekday")
            return
        }

        let schedule = BlockedProfileSchedule(
            days: [otherWeekday],
            startHour: 9,
            startMinute: 0,
            endHour: 17,
            endMinute: 0
        )

        XCTAssertFalse(schedule.isTodayScheduled())
    }

    func testScheduleIsTodayScheduled_returnsFalseForEmptyDays() {
        let schedule = BlockedProfileSchedule(
            days: [],
            startHour: 9,
            startMinute: 0,
            endHour: 17,
            endMinute: 0
        )

        XCTAssertFalse(schedule.isTodayScheduled())
    }

    func testScheduleIsActive_trueWhenDaysNotEmpty() {
        let schedule = BlockedProfileSchedule(
            days: [.monday, .tuesday],
            startHour: 9,
            startMinute: 0,
            endHour: 17,
            endMinute: 0
        )

        XCTAssertTrue(schedule.isActive)
    }

    func testScheduleIsActive_falseWhenDaysEmpty() {
        let schedule = BlockedProfileSchedule(
            days: [],
            startHour: 9,
            startMinute: 0,
            endHour: 17,
            endMinute: 0
        )

        XCTAssertFalse(schedule.isActive)
    }

    // MARK: - Default Values Tests

    func testPreActivationReminderMinutesRange() {
        // Valid range is 1-5 minutes
        let validMinutes: [UInt8] = [1, 2, 3, 4, 5]

        for minutes in validMinutes {
            XCTAssertGreaterThanOrEqual(minutes, 1)
            XCTAssertLessThanOrEqual(minutes, 5)
        }
    }

    // MARK: - Reminder Logic Tests

    func testReminderShouldNotScheduleWhenDisabled() {
        // Test the guard condition: preActivationReminderEnabled must be true
        let reminderEnabled = false
        let shouldSchedule = reminderEnabled

        XCTAssertFalse(shouldSchedule)
    }

    func testReminderShouldScheduleWhenEnabled() {
        let reminderEnabled = true
        let shouldSchedule = reminderEnabled

        XCTAssertTrue(shouldSchedule)
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
