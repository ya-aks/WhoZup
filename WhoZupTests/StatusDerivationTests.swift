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

    func testDismissAfterWindowHasElapsedYieldsRespondedLate() {
        let lateDismiss = alarmTime.addingTimeInterval(lateWindow + 60) // 1 minute past deadline
        let action = MemberAction(kind: .dismiss, timestamp: lateDismiss)

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [action],
            now: lateDismiss,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .respondedLate)
    }

    func testSnoozeAfterWindowHasElapsedYieldsRespondedLate() {
        let lateSnooze = alarmTime.addingTimeInterval(lateWindow + 60)
        let action = MemberAction(kind: .snooze, timestamp: lateSnooze)

        let status = StatusDerivation.status(
            scheduledTime: alarmTime,
            actions: [action],
            now: lateSnooze,
            lateWindow: lateWindow
        )

        XCTAssertEqual(status, .respondedLate)
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

final class MissedAlarmTests: XCTestCase {

    /// A fixed UTC calendar so weekdays and "HH:mm" resolve deterministically.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private let window: TimeInterval = 15 * 60

    /// Builds a UTC instant from y/m/d h:m.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d; comps.hour = h; comps.minute = mi
        return calendar.date(from: comps)!
    }

    func testTodayPastDeadlineIsMissed() {
        // 2026-08-22 is a Saturday. Alarm 06:30, now 09:00 → well past 06:45.
        let now = date(2026, 8, 22, 9, 0)
        let missed = MissedAlarm.missedOccurrences(
            time: "06:30", days: [], now: now, lookbackDays: 0,
            lateWindow: window, calendar: calendar
        )
        XCTAssertEqual(missed.map(\.dayKey), ["2026-08-22"])
        XCTAssertTrue(MissedAlarm.isTodayMissed(
            time: "06:30", days: [], now: now, lateWindow: window, calendar: calendar
        ))
    }

    func testWithinLateWindowIsNotMissed() {
        // now 06:40, deadline is 06:45 — still in the grace window.
        let now = date(2026, 8, 22, 6, 40)
        XCTAssertFalse(MissedAlarm.isTodayMissed(
            time: "06:30", days: [], now: now, lateWindow: window, calendar: calendar
        ))
    }

    func testBeforeFireTimeIsNotMissed() {
        let now = date(2026, 8, 22, 5, 0) // alarm hasn't fired yet today
        XCTAssertFalse(MissedAlarm.isTodayMissed(
            time: "06:30", days: [], now: now, lateWindow: window, calendar: calendar
        ))
    }

    func testWeekdayNotScheduledIsNotMissed() {
        // Saturday = weekday 7. Alarm only rings Mon–Fri (2–6).
        let now = date(2026, 8, 22, 9, 0)
        XCTAssertFalse(MissedAlarm.isTodayMissed(
            time: "06:30", days: [2, 3, 4, 5, 6], now: now, lateWindow: window, calendar: calendar
        ))
    }

    func testLookbackRespectsScheduledWeekdays() {
        // Now Sat 2026-08-22 09:00, look back a week for a Mon–Fri alarm.
        // Eligible past-deadline days: Mon 17 – Fri 21 (Sat 22 excluded by day set).
        let now = date(2026, 8, 22, 9, 0)
        let missed = MissedAlarm.missedOccurrences(
            time: "06:30", days: [2, 3, 4, 5, 6], now: now, lookbackDays: 7,
            lateWindow: window, calendar: calendar
        )
        XCTAssertEqual(
            missed.map(\.dayKey),
            ["2026-08-21", "2026-08-20", "2026-08-19", "2026-08-18", "2026-08-17"]
        )
    }

    // MARK: mostRecentFire — the occurrence a background response answers

    func testMostRecentFireIsTodayWhenAlarmAlreadyFired() {
        // Sat 09:00, alarm 06:30 already rang today → most recent fire is today.
        let now = date(2026, 8, 22, 9, 0)
        let fire = MissedAlarm.mostRecentFire(time: "06:30", days: [], now: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 8, 22, 6, 30))
    }

    func testMostRecentFireIsYesterdayWhenTodaysHasNotFiredYet() {
        // Sat 05:00 — today's 06:30 hasn't rung yet, so the last fire was Friday.
        let now = date(2026, 8, 22, 5, 0)
        let fire = MissedAlarm.mostRecentFire(time: "06:30", days: [], now: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 8, 21, 6, 30))
    }

    func testMostRecentFireSkipsUnscheduledWeekdays() {
        // Sun 09:00, Mon–Fri alarm (2–6): the last actual fire was Friday.
        let now = date(2026, 8, 23, 9, 0) // 2026-08-23 is a Sunday
        let fire = MissedAlarm.mostRecentFire(
            time: "06:30", days: [2, 3, 4, 5, 6], now: now, calendar: calendar
        )
        XCTAssertEqual(fire, date(2026, 8, 21, 6, 30))
    }

    func testAlarmSetAfterTodaysSlotIsNotMissed() {
        // Alarm 06:30, now 09:00 (past 06:45) — normally today is missed…
        let now = date(2026, 8, 22, 9, 0)
        XCTAssertTrue(MissedAlarm.isTodayMissed(
            time: "06:30", days: [], now: now, lateWindow: window, calendar: calendar))
        // …but an alarm only set at 08:00 today never fired its 06:30 slot for
        // this member, so it must NOT count as missed.
        XCTAssertFalse(MissedAlarm.isTodayMissed(
            time: "06:30", days: [], now: now, lateWindow: window,
            notBefore: date(2026, 8, 22, 8, 0), calendar: calendar))
        // An alarm set before the slot still counts once the deadline passes.
        XCTAssertTrue(MissedAlarm.isTodayMissed(
            time: "06:30", days: [], now: now, lateWindow: window,
            notBefore: date(2026, 8, 22, 6, 0), calendar: calendar))
    }

    /// The core of the repeating-alarm fix: an on-time dismiss on a later day is
    /// derived against *that day's* fire, not a stale earlier scheduled time.
    func testRepeatingDismissDerivedAgainstRecentFireIsOnTime() {
        // Alarm scheduled Mon; now Wed 06:03, three days later. Deriving against
        // the stale Monday time would read this as respondedLate; against Wed's
        // fire it is respondedOnTime.
        let now = date(2026, 8, 19, 6, 3) // Wednesday
        let fire = MissedAlarm.mostRecentFire(time: "06:00", days: [], now: now, calendar: calendar)!
        let status = StatusDerivation.status(
            scheduledTime: fire,
            actions: [MemberAction(kind: .dismiss, timestamp: now)],
            now: now,
            lateWindow: window
        )
        XCTAssertEqual(fire, date(2026, 8, 19, 6, 0))
        XCTAssertEqual(status, .respondedOnTime)
    }
}
