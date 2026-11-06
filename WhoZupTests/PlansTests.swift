//
//  PlansTests.swift
//  WhoZupTests
//
//  Plans rules with mock groups and members (no Firebase). Each test names the
//  decision it guards; the scenario table lives in docs/testing.md (P-unit).
//

import SwiftUI
import XCTest
@testable import WhoZup

@MainActor
final class PlansTests: XCTestCase {

    // MARK: Fixtures

    private let cal = Calendar.current

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func member(_ uid: String, you: Bool = false, status: RTStatus = .waiting, skips: Set<String> = []) -> RTMember {
        var m = RTMember(uid: uid, name: uid.capitalized, initials: String(uid.prefix(1)).uppercased(), isYou: you,
                         isAdmin: you, avatarColor: .gray, status: status, detail: "", alarm: nil)
        m.skips = skips
        return m
    }

    private func plan(_ id: String = "p", kind: RTPlanKind, alarm: String = "06:30", days: [Int] = [],
                      once: Bool = false, fire: Date? = nil, roster: [RTMember], flagNotUp: Int? = nil,
                      session: RTPlanSession? = nil) -> RTGroup {
        RTGroup(id: id, type: kind == .once ? .event : .shared, name: "Plan", alarm: alarm, admin: nil,
                adminUids: ["me"], isCurrentUserAdmin: true, event: nil, roster: roster,
                alarmDays: days, alarmOnce: once, alarmOnceFireDate: fire, planKind: kind,
                session: session, planFlagNotUpMinutes: flagNotUp)
    }

    private func session(everyoneIn: Bool, replies: [String: RTSessionAnswer], eta: [String: String] = [:]) -> RTPlanSession {
        RTPlanSession(dayKey: "2026-11-07", start: at(2026, 11, 7, 7), alarmAt: at(2026, 11, 7, 6, 30),
                      everyoneInByDefault: everyoneIn,
                      replies: replies.mapValues { RTSessionReply(answer: $0, eta: nil) }
                          .merging(eta.mapValues { RTSessionReply(answer: .runningLate, eta: $0) }) { $1 },
                      upcoming: [])
    }

    // MARK: Creating a plan (11-05 two quick questions)

    func testTwoQuestionsMapToStoredKinds() {
        XCTAssertEqual(RTPlanKind.from(weekly: false, ring: false), .once)
        XCTAssertEqual(RTPlanKind.from(weekly: false, ring: true), .onceAlarm)
        XCTAssertEqual(RTPlanKind.from(weekly: true, ring: true), .repeating)
        XCTAssertEqual(RTPlanKind.from(weekly: true, ring: false), .repeating, "weekly keeps repeat; the alarm switch carries 'no'")
        XCTAssertEqual(RTPlanKind.repeating.rawValue, "repeat", "storage key never changes")
        XCTAssertEqual(RTPlanKind.onceAlarm.rawValue, "onceAlarm")
    }

    func testRepeatingPlanAlarmIsLeadBeforeStartOnSessionDays() {
        let a = GroupRepository.planAlarm(start: at(2026, 11, 7, 7), leadMinutes: 30, days: [7])
        XCTAssertEqual(a.time, "06:30")
        XCTAssertEqual(a.days, [7])
    }

    func testPlanAlarmBeforeMidnightShiftsDaysBack() {
        // Starts Mon 00:15, alarm 30 min before = Sun 23:45: days shift Mon(2) → Sun(1), Sun(1) → Sat(7).
        let a = GroupRepository.planAlarm(start: at(2026, 11, 9, 0, 15), leadMinutes: 30, days: [2, 1])
        XCTAssertEqual(a.time, "23:45")
        XCTAssertEqual(a.days, [1, 7])
    }

    func testOneTimePlanAlarmAnchorsAMinuteBefore() {
        // 11-05 backward compatibility: old builds ring at the first occurrence after alarmSetAt.
        let alarm = at(2026, 11, 7, 6, 30)
        XCTAssertEqual(GroupRepository.onceAnchor(alarm), alarm.addingTimeInterval(-60))
    }

    // MARK: Sessions

    func testWeeklySessionsFollowTheirDays() {
        // Wed 4 Nov 10:00; Tue + Thu at 06:00.
        let next = GroupRepository.planSessions(kind: .repeating, meetAt: nil, startTime: "06:00", alarmDays: [3, 5],
                                                alarmLeadMinutes: 30, count: 3, now: at(2026, 11, 4, 10))
        XCTAssertEqual(next.map { cal.component(.weekday, from: $0) }, [5, 3, 5])
    }

    func testSessionStaysNextUntilTwoHoursAfterStart() {
        let next = GroupRepository.planSessions(kind: .repeating, meetAt: nil, startTime: "06:00", alarmDays: [5],
                                                alarmLeadMinutes: 30, count: 1, now: at(2026, 11, 5, 7, 30))
        XCTAssertEqual(next.first, at(2026, 11, 5, 6))
    }

    func testOneTimePlanHasOneSessionUntilItsOver() {
        let meet = at(2026, 11, 7, 5)
        XCTAssertEqual(GroupRepository.planSessions(kind: .onceAlarm, meetAt: meet, startTime: nil, alarmDays: [],
                                                    alarmLeadMinutes: 45, count: 4, now: at(2026, 11, 6, 20)), [meet])
        XCTAssertEqual(GroupRepository.planSessions(kind: .onceAlarm, meetAt: meet, startTime: nil, alarmDays: [],
                                                    alarmLeadMinutes: 45, count: 4, now: at(2026, 11, 7, 8)), [])
    }

    func testSessionsForAnAlarmBeforeMidnightLandOnTheSessionDay() {
        // Stored alarm days are Sun(1) for a Mon 00:15 start: sessions are Mondays.
        let next = GroupRepository.planSessions(kind: .repeating, meetAt: nil, startTime: "00:15", alarmDays: [1],
                                                alarmLeadMinutes: 30, count: 1, now: at(2026, 11, 5, 12))
        XCTAssertEqual(next.first.map { cal.component(.weekday, from: $0) }, 2)
    }

    // MARK: Headcount (11-05 tap a count to see who)

    func testEveryoneInByDefaultCountsSilenceAsIn() {
        let roster = [member("me", you: true), member("ana"), member("kabir"), member("ethan")]
        let s = session(everyoneIn: true, replies: ["kabir": .skipping], eta: ["ethan": "+15"])
        let h = RTHeadcount(group: plan(kind: .repeating, roster: roster, session: s), session: s)
        XCTAssertEqual(h.coming, 2)
        XCTAssertEqual(h.late, 1)
        XCTAssertEqual(h.cant, 1)
        XCTAssertEqual(h.waiting, 0)
        XCTAssertEqual(h.people.first { $0.member.uid == "ana" }?.detail, "in by default")
        XCTAssertEqual(h.people.first { $0.member.uid == "ethan" }?.detail, "ETA +15")
    }

    func testAskEachTimeLeavesSilenceAsWaiting() {
        let roster = [member("me", you: true), member("ana"), member("kabir")]
        let s = session(everyoneIn: false, replies: ["me": .coming])
        let h = RTHeadcount(group: plan(kind: .repeating, roster: roster, session: s), session: s)
        XCTAssertEqual(h.coming, 1)
        XCTAssertEqual(h.waiting, 2)
        XCTAssertEqual(h.waitingNames.sorted(), ["Ana", "Kabir"])
        XCTAssertEqual(h.invited, 3)
    }

    func testAskNowAudienceMatchesTheServer() {
        // Never the asker, never anyone who can't make it (mirrors functions/audienceFor).
        let roster = [member("me", you: true), member("ana"), member("kabir"), member("ethan")]
        let s = session(everyoneIn: false, replies: ["me": .coming, "ana": .coming, "kabir": .skipping])
        let h = RTHeadcount(group: plan(kind: .repeating, roster: roster, session: s), session: s)
        XCTAssertEqual(h.recipients("unanswered"), 1, "ethan")
        XCTAssertEqual(h.recipients("yes"), 1, "ana, not me")
        XCTAssertEqual(h.recipients("everyone"), 2, "ana + ethan, not me, not kabir")
    }

    // MARK: Morning of a plan with an alarm (11-05 host-only Not up)

    func testNotUpIsEmptyBeforeTheFlagTime() {
        let alarm = at(2026, 11, 7, 6, 30)
        let roster = [member("me", you: true, status: .wokeUp), member("ana"), member("kabir", status: .snoozed)]
        let s = session(everyoneIn: true, replies: [:])
        let g = plan(kind: .onceAlarm, roster: roster, flagNotUp: 10, session: s)
        XCTAssertTrue(RTMorningOfCard.state(group: g, session: s, alarmAt: alarm, now: alarm.addingTimeInterval(5 * 60)).flagged.isEmpty)
    }

    func testNotUpFlagsExpectedPeopleNotUpExceptYou() {
        let alarm = at(2026, 11, 7, 6, 30)
        let roster = [member("me", you: true, status: .waiting), member("ana", status: .wokeUp),
                      member("kabir", status: .snoozed), member("ethan", status: .runningLate), member("olivia")]
        let s = session(everyoneIn: true, replies: ["olivia": .skipping])
        let g = plan(kind: .onceAlarm, roster: roster, flagNotUp: 10, session: s)
        let st = RTMorningOfCard.state(group: g, session: s, alarmAt: alarm, now: alarm.addingTimeInterval(11 * 60))
        XCTAssertEqual(st.expected.map(\.uid).sorted(), ["ana", "ethan", "kabir", "me"], "skipping isn't expected")
        XCTAssertEqual(st.up.map(\.uid).sorted(), ["ana", "ethan"], "running late counts as up")
        XCTAssertEqual(st.flagged.map(\.uid), ["kabir"], "you are never flagged; skippers aren't either")
    }

    func testNoFlagTimeMeansNoNotUpList() {
        let alarm = at(2026, 11, 7, 6, 30)
        let s = session(everyoneIn: true, replies: [:])
        let g = plan(kind: .onceAlarm, roster: [member("me", you: true), member("ana")], flagNotUp: nil, session: s)
        XCTAssertTrue(RTMorningOfCard.state(group: g, session: s, alarmAt: alarm, now: alarm.addingTimeInterval(3600)).flagged.isEmpty)
    }

    // MARK: Skipping ahead keeps your alarm quiet (11-05)

    func testSkippingADateRemovesThatWeekdayThisWeek() {
        let now = at(2026, 11, 4, 10) // Wed
        let g = plan(kind: .repeating, days: [3, 5, 7], roster: [member("me", you: true, skips: ["2026-11-07"])])
        XCTAssertEqual(RTAlarmSync.ringDays(g, now: now), [3, 5], "Sat 7 Nov is skipped")
    }

    func testSkippingEveryDayThisWeekSkipsTheAlarm() {
        let now = at(2026, 11, 4, 10)
        let g = plan(kind: .repeating, days: [7], roster: [member("me", you: true, skips: ["2026-11-07"])])
        XCTAssertTrue(RTAlarmSync.isSkipped(g, now: now))
        XCTAssertNil(RTAlarmSync.desiredAlarms(for: [g], now: now)["06:30"], "no alarm rings for a skipped week")
    }

    func testSkippedWeekdayComesBackNextWeekWithoutTheAppOpening() {
        let now = at(2026, 11, 4, 10) // Wed
        let g = plan(kind: .repeating, days: [3, 5, 7], roster: [member("me", you: true, skips: ["2026-11-07"])])
        let back = RTAlarmSync.backFire(forTime: "06:30", in: [g], now: now)
        XCTAssertEqual(back?.date, at(2026, 11, 14, 6, 30), "Sat 14 Nov still rings")
        XCTAssertEqual(back?.groupIds, ["p"])
        XCTAssertEqual(RTAlarmSync.desiredAlarms(for: [g], now: now)["06:30#back"], ["p"])
    }

    func testCatchUpAlarmSkipsADateThatIsAlsoSkipped() {
        let now = at(2026, 11, 4, 10)
        let g = plan(kind: .repeating, days: [7], roster: [member("me", you: true, skips: ["2026-11-07", "2026-11-14"])])
        XCTAssertEqual(RTAlarmSync.backFire(forTime: "06:30", in: [g], now: now)?.date, at(2026, 11, 21, 6, 30))
    }

    func testNoCatchUpAlarmWithoutSkipsOrWhenAnotherGroupKeepsTheDay() {
        let now = at(2026, 11, 4, 10)
        let plain = plan("a", kind: .repeating, days: [7], roster: [member("me", you: true)])
        XCTAssertNil(RTAlarmSync.backFire(forTime: "06:30", in: [plain], now: now))
        let skipped = plan("s", kind: .repeating, days: [7], roster: [member("me", you: true, skips: ["2026-11-07"])])
        let daily = plan("d", kind: .repeating, roster: [member("me", you: true)])
        XCTAssertNil(RTAlarmSync.backFire(forTime: "06:30", in: [skipped, daily], now: now), "Saturday still rings for the daily group")
    }

    // MARK: Snooze then Stop is a missed habit day (11-06, E11)

    func testTodaysRoutineShowsAMissAfterASnooze() {
        let habit = MemberHabit(name: "Wake", steps: [HabitStep(title: "Water", tiny: "Sip")], windowMinutes: 30, showSteps: true)
        let snoozed = plan(kind: .repeating, roster: [member("me", you: true, status: .snoozed)])
        XCTAssertEqual(RoutineEntry.missedToday(group: snoozed, habit: habit), "Snoozed today · no routine")
        XCTAssertNil(RoutineEntry.startableUntil(group: snoozed, habit: habit, now: Date()), "no Start habit after a snooze")
        let up = plan(kind: .repeating, roster: [member("me", you: true, status: .wokeUp)])
        XCTAssertNil(RoutineEntry.missedToday(group: up, habit: habit))
        var list = MemberHabit(name: "Pack", steps: [HabitStep(title: "Bag", tiny: "")], windowMinutes: 30, showSteps: true)
        list.isChecklist = true
        XCTAssertNil(RoutineEntry.missedToday(group: snoozed, habit: list), "a checklist opens after any Stop")
    }

    func testSkippingAOneTimePlanSkipsItsAlarm() {
        let fire = at(2026, 11, 7, 6, 30)
        let g = plan(kind: .onceAlarm, once: true, fire: fire, roster: [member("me", you: true, skips: ["2026-11-07"])])
        XCTAssertTrue(RTAlarmSync.isSkipped(g, now: at(2026, 11, 5, 9)))
    }

    func testOneTimePlanAlarmUsesItsOwnSlotAndEndsTwoHoursLater() {
        let fire = at(2026, 11, 7, 6, 30)
        let g = plan(kind: .onceAlarm, once: true, fire: fire, roster: [member("me", you: true)])
        XCTAssertEqual(RTAlarmSync.slotKey(for: g), "06:30#once")
        XCTAssertFalse(RTAlarmSync.onceIsOver(g, now: fire.addingTimeInterval(60 * 60)))
        XCTAssertTrue(RTAlarmSync.onceIsOver(g, now: fire.addingTimeInterval(2 * 60 * 60 + 60)))
        XCTAssertEqual(RTAlarmSync.desiredAlarms(for: [g], now: fire.addingTimeInterval(-3600))["06:30#once"], ["p"])
    }

    func testNoAlarmPlanSchedulesNothing() {
        let g = plan(kind: .repeating, alarm: "", days: [7], roster: [member("me", you: true)])
        XCTAssertTrue(RTAlarmSync.desiredAlarms(for: [g], now: at(2026, 11, 4, 10)).isEmpty)
    }

    // MARK: Rise Report only for things that repeat (11-05)

    func testRiseReportOnlyForRepeatingPlans() {
        let me = [member("me", you: true)]
        XCTAssertTrue(plan(kind: .repeating, roster: me).hasRiseReport)
        XCTAssertFalse(plan(kind: .onceAlarm, once: true, roster: me).hasRiseReport)
        XCTAssertFalse(plan(kind: .once, roster: me).hasRiseReport)
    }
}
