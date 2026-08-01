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

    func testDismissAfterWindowElapsedYieldsSilentLate() {
        let recorder = AlarmStatusRecorder(lateWindow: 10 * 60)
        let id = UUID()
        let scheduledTime = Date(timeIntervalSince1970: 1_000_000)
        recorder.registerScheduled(id: id, scheduledTime: scheduledTime)

        let result = recorder.record(kind: .dismiss, alarmID: id, now: scheduledTime.addingTimeInterval(11 * 60))

        XCTAssertEqual(result?.status, .silentLate)
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
