//
//  AlarmStatusRecorderTests.swift
//  WhoZupTests
//
//  Unit tests for the AlarmKit state-transition → MemberAction →
//  StatusDerivation pipeline, using synthetic AlarmSnapshots (no real
//  AlarmManager involved).
//

import AlarmKit
import XCTest
@testable import WhoZup

@MainActor
final class AlarmStatusRecorderTests: XCTestCase {

    // MARK: Transition mapping (pure)

    func testAlertingToGoneMapsToDismiss() {
        let id = UUID()
        let transitions = AlarmTransitionMapper.transitions(
            from: [AlarmSnapshot(id: id, state: .alerting)],
            to: []
        )
        XCTAssertEqual(transitions, [AlarmTransition(alarmID: id, kind: .dismiss)])
    }

    func testAlertingToCountdownMapsToSnooze() {
        let id = UUID()
        let transitions = AlarmTransitionMapper.transitions(
            from: [AlarmSnapshot(id: id, state: .alerting)],
            to: [AlarmSnapshot(id: id, state: .countdown)]
        )
        XCTAssertEqual(transitions, [AlarmTransition(alarmID: id, kind: .snooze)])
    }

    func testCountdownToGoneMapsToDismiss() {
        let id = UUID()
        let transitions = AlarmTransitionMapper.transitions(
            from: [AlarmSnapshot(id: id, state: .countdown)],
            to: []
        )
        XCTAssertEqual(transitions, [AlarmTransition(alarmID: id, kind: .dismiss)])
    }

    func testAlertingToScheduledMapsToDismiss() {
        // A stopped *repeating* alarm is rescheduled, not deleted.
        let id = UUID()
        let transitions = AlarmTransitionMapper.transitions(
            from: [AlarmSnapshot(id: id, state: .alerting)],
            to: [AlarmSnapshot(id: id, state: .scheduled)]
        )
        XCTAssertEqual(transitions, [AlarmTransition(alarmID: id, kind: .dismiss)])
    }

    func testCountdownToScheduledMapsToDismiss() {
        let id = UUID()
        let transitions = AlarmTransitionMapper.transitions(
            from: [AlarmSnapshot(id: id, state: .countdown)],
            to: [AlarmSnapshot(id: id, state: .scheduled)]
        )
        XCTAssertEqual(transitions, [AlarmTransition(alarmID: id, kind: .dismiss)])
    }

    // MARK: Check-in reminder schedule (pure)

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testCheckInFiresFollowSelectedWeekdays() {
        // 2026-11-02 is a Monday (weekday 2).
        let record = AlarmRecord(groupIds: ["g"], scheduledTime: date("2026-11-02 06:30"),
                                 time: "06:30", days: [2, 4])
        let fires = AlarmCheckInNotifier.fires(of: record, from: date("2026-11-02 00:00"), to: date("2026-11-08 23:59"))
        XCTAssertEqual(fires, [date("2026-11-02 06:30"), date("2026-11-04 06:30")])
    }

    func testCheckInFiresEveryDayWhenNoDays() {
        let record = AlarmRecord(groupIds: ["g"], scheduledTime: date("2026-11-02 06:30"), time: "06:30", days: [])
        let fires = AlarmCheckInNotifier.fires(of: record, from: date("2026-11-02 07:00"), to: date("2026-11-04 23:59"))
        XCTAssertEqual(fires, [date("2026-11-03 06:30"), date("2026-11-04 06:30")])
    }

    func testCheckInFiresOneTimeAlarmOnlyAtItsDate() {
        let record = AlarmRecord(groupIds: ["g"], scheduledTime: date("2026-11-03 07:15"))
        XCTAssertEqual(
            AlarmCheckInNotifier.fires(of: record, from: date("2026-11-02 00:00"), to: date("2026-11-09 00:00")),
            [date("2026-11-03 07:15")]
        )
        XCTAssertTrue(AlarmCheckInNotifier.fires(of: record, from: date("2026-11-04 00:00"), to: date("2026-11-09 00:00")).isEmpty)
    }

    func testCheckInIdentifierRoundTrips() {
        let id = UUID()
        let fire = date("2026-11-02 06:30")
        let parsed = AlarmCheckInNotifier.parse(AlarmCheckInNotifier.identifier(alarmID: id, fire: fire))
        XCTAssertEqual(parsed?.alarmID, id)
        XCTAssertEqual(parsed?.fire, fire)
        XCTAssertNil(AlarmCheckInNotifier.parse("alarm.checkin.resolved"))
    }

    func testScheduledToAlertingMapsToNothing() {
        let id = UUID()
        let transitions = AlarmTransitionMapper.transitions(
            from: [AlarmSnapshot(id: id, state: .scheduled)],
            to: [AlarmSnapshot(id: id, state: .alerting)]
        )
        XCTAssertTrue(transitions.isEmpty)
    }

    func testUnchangedSnapshotsMapToNothing() {
        let id = UUID()
        let snapshots = [AlarmSnapshot(id: id, state: .alerting)]
        XCTAssertTrue(AlarmTransitionMapper.transitions(from: snapshots, to: snapshots).isEmpty)
    }

    // MARK: Recording + status derivation

    func testDismissWithinWindowYieldsRespondedOnTime() {
        let recorder = AlarmStatusRecorder(lateWindow: 10 * 60)
        let id = UUID()
        let scheduledTime = Date(timeIntervalSince1970: 1_000_000)
        recorder.registerScheduled(id: id, scheduledTime: scheduledTime)

        let result = recorder.record(kind: .dismiss, alarmID: id, now: scheduledTime.addingTimeInterval(60))

        XCTAssertEqual(result?.status, .respondedOnTime)
        XCTAssertEqual(recorder.lastResult, result)
    }

    func testSnoozeWithinWindowYieldsSnoozed() {
        let recorder = AlarmStatusRecorder(lateWindow: 10 * 60)
        let id = UUID()
        let scheduledTime = Date(timeIntervalSince1970: 1_000_000)
        recorder.registerScheduled(id: id, scheduledTime: scheduledTime)

        let result = recorder.record(kind: .snooze, alarmID: id, now: scheduledTime.addingTimeInterval(60))

        XCTAssertEqual(result?.status, .snoozed)
    }

    func testDismissAfterWindowElapsedYieldsRespondedLate() {
        let recorder = AlarmStatusRecorder(lateWindow: 10 * 60)
        let id = UUID()
        let scheduledTime = Date(timeIntervalSince1970: 1_000_000)
        recorder.registerScheduled(id: id, scheduledTime: scheduledTime)

        let result = recorder.record(kind: .dismiss, alarmID: id, now: scheduledTime.addingTimeInterval(11 * 60))

        XCTAssertEqual(result?.status, .respondedLate)
    }

    func testRecordForUnregisteredAlarmReturnsNil() {
        let recorder = AlarmStatusRecorder()

        let result = recorder.record(kind: .dismiss, alarmID: UUID())

        XCTAssertNil(result)
        XCTAssertNil(recorder.lastResult)
    }

    // MARK: End-to-end ingest

    func testIngestAlertingThenGoneRecordsDismiss() {
        let recorder = AlarmStatusRecorder(lateWindow: 10 * 60)
        let id = UUID()
        let scheduledTime = Date(timeIntervalSince1970: 1_000_000)
        recorder.registerScheduled(id: id, scheduledTime: scheduledTime)

        recorder.ingest(snapshots: [AlarmSnapshot(id: id, state: .alerting)], now: scheduledTime)
        recorder.ingest(snapshots: [], now: scheduledTime.addingTimeInterval(30))

        XCTAssertEqual(recorder.lastResult?.action.kind, .dismiss)
        XCTAssertEqual(recorder.lastResult?.status, .respondedOnTime)
    }

    func testIngestAlertingThenCountdownRecordsSnooze() {
        let recorder = AlarmStatusRecorder(lateWindow: 10 * 60)
        let id = UUID()
        let scheduledTime = Date(timeIntervalSince1970: 1_000_000)
        recorder.registerScheduled(id: id, scheduledTime: scheduledTime)

        recorder.ingest(snapshots: [AlarmSnapshot(id: id, state: .alerting)], now: scheduledTime)
        recorder.ingest(snapshots: [AlarmSnapshot(id: id, state: .countdown)], now: scheduledTime.addingTimeInterval(30))

        XCTAssertEqual(recorder.lastResult?.action.kind, .snooze)
        XCTAssertEqual(recorder.lastResult?.status, .snoozed)
    }

    func testUnregisteredThenCancelledAlarmRecordsNothing() {
        let recorder = AlarmStatusRecorder()
        let id = UUID()
        let scheduledTime = Date(timeIntervalSince1970: 1_000_000)
        recorder.registerScheduled(id: id, scheduledTime: scheduledTime)
        recorder.ingest(snapshots: [AlarmSnapshot(id: id, state: .alerting)], now: scheduledTime)

        // Programmatic cancel: unregister first, then the alarm disappears.
        recorder.unregister(id: id)
        recorder.ingest(snapshots: [], now: scheduledTime.addingTimeInterval(30))

        XCTAssertNil(recorder.lastResult)
    }
}
