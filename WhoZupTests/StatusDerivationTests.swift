//
//  StatusDerivationTests.swift
//  WhoZupTests
//

import XCTest
@testable import WhoZup

final class StatusDerivationTests: XCTestCase {

    private let alarmTime = Date(timeIntervalSince1970: 1_000_000)
    private let lateWindow: TimeInterval = 10 * 60 // 10 minutes

    func testDismissYieldsRespondedOnTime() {
        let dismissTime = alarmTime.addingTimeInterval(60) // 1 minute after alarm
        let action = MemberAction(kind: .dismiss, timestamp: dismissTime)

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [action],
            now: dismissTime,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .respondedOnTime)
    }

    func testSnoozeYieldsSnoozed() {
        let snoozeTime = alarmTime.addingTimeInterval(60)
        let action = MemberAction(kind: .snooze, timestamp: snoozeTime)

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [action],
            now: snoozeTime,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .snoozed)
    }

    func testNoActionWithinWindowYieldsSilentLate() {
        let now = alarmTime.addingTimeInterval(lateWindow + 1) // window has elapsed

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [],
            now: now,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .silentLate)
    }

    func testNoActionBeforeWindowElapsesYieldsPending() {
        let now = alarmTime.addingTimeInterval(60) // window has not yet elapsed

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [],
            now: now,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .pending)
    }

    func testActionExactlyAtBoundaryCountsAsInWindow() {
        let boundary = alarmTime.addingTimeInterval(lateWindow)
        let action = MemberAction(kind: .dismiss, timestamp: boundary)

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [action],
            now: boundary,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .respondedOnTime)
    }

    func testActionAfterWindowHasElapsedIsIgnoredAndYieldsSilentLate() {
        let lateDismiss = alarmTime.addingTimeInterval(lateWindow + 60) // 1 minute past deadline
        let action = MemberAction(kind: .dismiss, timestamp: lateDismiss)

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [action],
            now: lateDismiss,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .silentLate)
    }

    func testSnoozeFollowedByLaterDismissWithinWindowResolvesToRespondedOnTime() {
        let snoozeTime = alarmTime.addingTimeInterval(60)
        let dismissTime = alarmTime.addingTimeInterval(120)
        let actions = [
            MemberAction(kind: .snooze, timestamp: snoozeTime),
            MemberAction(kind: .dismiss, timestamp: dismissTime)
        ]

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: actions,
            now: dismissTime,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .respondedOnTime)
    }

    func testActionBeforeScheduledTimeIsIgnored() {
        let earlyAction = MemberAction(kind: .dismiss, timestamp: alarmTime.addingTimeInterval(-60))
        let now = alarmTime.addingTimeInterval(lateWindow + 1)

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [earlyAction],
            now: now,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .silentLate)
    }
}
