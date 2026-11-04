//
//  AlarmDeduplicationTests.swift
//  WhoZupTests
//
//  Covers the rule that groups sharing an alarm time share one alarm, so the
//  phone rings once at 06:30 no matter how many 06:30 groups you're in.
//

import XCTest
@testable import WhoZup

@MainActor
final class AlarmDeduplicationTests: XCTestCase {

    private func group(
        id: String,
        type: RTGroupType = .accountability,
        name: String = "Group",
        alarm: String
    ) -> RTGroup {
        RTGroup(
            id: id,
            type: type,
            name: name,
            alarm: alarm,
            admin: nil,
            adminUids: [],
            isCurrentUserAdmin: false,
            event: nil,
            roster: []
        )
    }

    func testGroupsAtTheSameTimeCollapseIntoOneAlarm() {
        let desired = RTAlarmSync.desiredAlarms(for: [
            group(id: "a", name: "Morning Crew", alarm: "06:30"),
            group(id: "b", name: "Gym Buddies", alarm: "06:30"),
            group(id: "c", name: "Study Group", alarm: "06:30"),
        ])

        XCTAssertEqual(desired.count, 1, "three 06:30 groups must schedule one alarm")
        XCTAssertEqual(desired["06:30"], ["a", "b", "c"])
    }

    func testDistinctTimesGetDistinctAlarms() {
        let desired = RTAlarmSync.desiredAlarms(for: [
            group(id: "a", alarm: "06:30"),
            group(id: "b", alarm: "07:00"),
        ])

        XCTAssertEqual(desired.count, 2)
        XCTAssertEqual(desired["06:30"], ["a"])
        XCTAssertEqual(desired["07:00"], ["b"])
    }

    func testAccountabilityAndSharedGroupsShareOneAlarm() {
        // The two alarm-bearing types are deduplicated against each other, not
        // just within a type.
        let desired = RTAlarmSync.desiredAlarms(for: [
            group(id: "a", type: .accountability, alarm: "06:30"),
            group(id: "b", type: .shared, alarm: "06:30"),
        ])

        XCTAssertEqual(desired.count, 1)
        XCTAssertEqual(desired["06:30"], ["a", "b"])
    }

    func testEventGroupsNeverScheduleAlarms() {
        let desired = RTAlarmSync.desiredAlarms(for: [
            group(id: "a", type: .event, alarm: "06:30"),
        ])

        XCTAssertTrue(desired.isEmpty)
    }

    func testGroupsWithoutATimeAreIgnored() {
        let desired = RTAlarmSync.desiredAlarms(for: [
            group(id: "a", alarm: ""),
            group(id: "b", alarm: "06:30"),
        ])

        XCTAssertEqual(desired.count, 1)
        XCTAssertEqual(desired["06:30"], ["b"])
    }

    func testGroupIdOrderIsStableRegardlessOfInputOrder() {
        // Reconcile compares against the previous run; unstable ordering would
        // look like a change and cancel/reschedule a live alarm for nothing.
        let forward = RTAlarmSync.desiredAlarms(for: [
            group(id: "c", alarm: "06:30"),
            group(id: "a", alarm: "06:30"),
            group(id: "b", alarm: "06:30"),
        ])
        let reversed = RTAlarmSync.desiredAlarms(for: [
            group(id: "b", alarm: "06:30"),
            group(id: "a", alarm: "06:30"),
            group(id: "c", alarm: "06:30"),
        ])

        XCTAssertEqual(forward["06:30"], reversed["06:30"])
        XCTAssertEqual(forward["06:30"], ["a", "b", "c"])
    }

    func testNoGroupsMeansNoAlarms() {
        XCTAssertTrue(RTAlarmSync.desiredAlarms(for: []).isEmpty)
    }

    // MARK: Alarm identity

    func testAlarmIDIsStableForTheSameTime() {
        // This is what stops a cold start from scheduling a second alarm
        // alongside the one a previous launch left on the system.
        XCTAssertEqual(
            RTAlarmSync.alarmID(forTime: "06:30"),
            RTAlarmSync.alarmID(forTime: "06:30")
        )
    }

    func testDifferentTimesGetDifferentAlarmIDs() {
        XCTAssertNotEqual(
            RTAlarmSync.alarmID(forTime: "06:30"),
            RTAlarmSync.alarmID(forTime: "06:31")
        )
        XCTAssertNotEqual(
            RTAlarmSync.alarmID(forTime: "06:30"),
            RTAlarmSync.alarmID(forTime: "18:30")
        )
    }

    func testAlarmIDIsAWellFormedV5UUID() {
        // Version and variant bits must be set, or the value isn't a legal UUID
        // and AlarmKit may reject or normalize it.
        let uuid = RTAlarmSync.alarmID(forTime: "06:30")
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

        XCTAssertEqual(bytes[6] & 0xF0, 0x50, "version nibble should be 5")
        XCTAssertEqual(bytes[8] & 0xC0, 0x80, "variant bits should be RFC 4122")
    }

    func testEditingATimeChangesWhichAlarmIsTargeted() {
        // Editing 06:30 -> 07:00 must cancel the 06:30 alarm and address the
        // 07:00 one, not leave both live.
        let before = RTAlarmSync.desiredAlarms(for: [group(id: "a", alarm: "06:30")])
        let after = RTAlarmSync.desiredAlarms(for: [group(id: "a", alarm: "07:00")])

        XCTAssertEqual(Set(before.keys), ["06:30"])
        XCTAssertEqual(Set(after.keys), ["07:00"])
        XCTAssertNotEqual(
            RTAlarmSync.alarmID(forTime: "06:30"),
            RTAlarmSync.alarmID(forTime: "07:00")
        )
    }

    func testDeletingTheOnlyGroupLeavesNothingDesired() {
        let before = RTAlarmSync.desiredAlarms(for: [group(id: "a", alarm: "06:30")])
        let after = RTAlarmSync.desiredAlarms(for: [])

        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(after.isEmpty, "the 06:30 alarm has nothing left wanting it")
    }

    func testDeletingOneOfTwoGroupsSharingATimeKeepsTheAlarm() {
        let after = RTAlarmSync.desiredAlarms(for: [group(id: "b", alarm: "06:30")])

        XCTAssertEqual(after["06:30"], ["b"], "the shared alarm survives for the remaining group")
    }

    // MARK: Time zones

    func testSameZoneConversionIsIdentity() {
        let zone = TimeZone.current
        XCTAssertEqual(RTAlarmTime.localTime(of: "06:30", in: zone), "06:30")
    }

    func testConversionAcrossZonesShiftsByTheOffsetDifference() throws {
        let kolkata = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))

        // Compare the absolute instants rather than hard-coding a wall clock,
        // so the test doesn't break when either zone's DST rules shift.
        let instant = RTAlarmTime.nextDate(for: "06:30", in: kolkata)
        var calendar = Calendar.current
        calendar.timeZone = london
        let londonParts = calendar.dateComponents([.hour, .minute], from: instant)

        let offsetDifference = kolkata.secondsFromGMT(for: instant) - london.secondsFromGMT(for: instant)
        let expectedMinutes = ((6 * 60 + 30) - offsetDifference / 60 + 24 * 60) % (24 * 60)

        XCTAssertEqual((londonParts.hour ?? 0) * 60 + (londonParts.minute ?? 0), expectedMinutes)
    }

    func testNextDateInAZoneLandsOnThatZonesWallClock() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let instant = RTAlarmTime.nextDate(for: "06:30", in: tokyo)

        var calendar = Calendar.current
        calendar.timeZone = tokyo
        let parts = calendar.dateComponents([.hour, .minute], from: instant)

        XCTAssertEqual(parts.hour, 6)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertGreaterThan(instant, Date(), "must resolve to the next future occurrence")
    }

    func testSignatureChangesWithTimeZone() throws {
        let groups = [group(id: "a", alarm: "06:30")]
        let kolkata = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))

        XCTAssertNotEqual(
            RTAlarmSync.signature(for: groups, timeZone: kolkata),
            RTAlarmSync.signature(for: groups, timeZone: london),
            "a zone change must retrigger reconciliation even when local times match"
        )
    }

    // MARK: Anchor semantics

    private func firestoreGroup(alarmTimeZone: String?, alarmAnchor: String?) -> FirestoreGroup {
        FirestoreGroup(
            type: "shared",
            name: "Group",
            adminUids: [],
            memberUids: [],
            inviteCode: "ABC123",
            alarmTime: "06:30",
            alarmTimeZone: alarmTimeZone,
            alarmAnchor: alarmAnchor
        )
    }

    func testExplicitAnchorIsHonoured() {
        XCTAssertEqual(
            firestoreGroup(alarmTimeZone: "Asia/Kolkata", alarmAnchor: "local").anchor,
            .localTime
        )
        XCTAssertEqual(
            firestoreGroup(alarmTimeZone: "Asia/Kolkata", alarmAnchor: "moment").anchor,
            .sameMoment
        )
    }

    func testLegacyGroupWithNoZoneFallsBackToLocalTime() {
        // Pre-timezone groups can't be read as an absolute instant — nothing
        // records which zone their wall clock was picked in.
        XCTAssertEqual(
            firestoreGroup(alarmTimeZone: nil, alarmAnchor: nil).anchor,
            .localTime
        )
    }

    func testGroupWithZoneButNoAnchorKeepsSameMoment() {
        // Written after zones landed but before the toggle: those were created
        // under same-moment semantics and must not silently change meaning.
        XCTAssertEqual(
            firestoreGroup(alarmTimeZone: "Asia/Kolkata", alarmAnchor: nil).anchor,
            .sameMoment
        )
    }

    func testUnrecognisedAnchorValueFallsBack() {
        XCTAssertEqual(
            firestoreGroup(alarmTimeZone: nil, alarmAnchor: "nonsense").anchor,
            .localTime
        )
    }

    func testInvitePreviewOnlyConvertsForSameMoment() throws {
        var invite = InviteDoc(
            groupId: "g", groupName: "Morning Crew", createdBy: "u",
            groupType: "shared", alarmTime: "06:30",
            alarmTimeZone: "Asia/Kolkata", alarmAnchor: "local"
        )
        XCTAssertEqual(invite.localAlarmTime, "06:30", "local-time groups read as-is")

        invite.alarmAnchor = "moment"
        let kolkata = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        XCTAssertEqual(
            invite.localAlarmTime,
            RTAlarmTime.localTime(of: "06:30", in: kolkata),
            "same-moment groups convert into the reader's zone"
        )
    }

    func testGroupsLandingOnTheSameLocalTimeStillShareOneAlarm() {
        // Two shared groups set in different zones can convert to the same
        // local wall clock; they must still produce a single alarm.
        let desired = RTAlarmSync.desiredAlarms(for: [
            group(id: "a", type: .shared, alarm: "06:30"),
            group(id: "b", type: .shared, alarm: "06:30"),
        ])

        XCTAssertEqual(desired.count, 1)
        XCTAssertEqual(desired["06:30"], ["a", "b"])
    }

    /// A one-time Check-ins alarm gets its own slot while it's still to ring,
    /// and drops out a couple of hours after it rang so it isn't re-armed for tomorrow.
    func testOneTimeCheckInAlarmRingsOnlyOnce() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func once(firing fire: Date) -> RTGroup {
            RTGroup(id: "a", type: .accountability, name: "G", alarm: "06:30", admin: nil, adminUids: [],
                    isCurrentUserAdmin: true, event: nil, roster: [],
                    alarmOnce: true, alarmOnceFireDate: fire)
        }
        XCTAssertEqual(RTAlarmSync.desiredAlarms(for: [once(firing: now.addingTimeInterval(3600))], now: now),
                       ["06:30#once": ["a"]])
        XCTAssertEqual(RTAlarmSync.desiredAlarms(for: [once(firing: now.addingTimeInterval(-30 * 60))], now: now),
                       ["06:30#once": ["a"]], "still wanted while it may be snoozing")
        XCTAssertTrue(RTAlarmSync.desiredAlarms(for: [once(firing: now.addingTimeInterval(-3 * 3600))], now: now).isEmpty)
    }
}
