//
//  HabitModelsTests.swift
//  WhoZupTests
//

import FirebaseFirestore
import XCTest
@testable import WhoZup

@MainActor
final class HabitModelsTests: XCTestCase {

    func testDraftNeedsANameAndAStep() {
        var draft = RTHabitDraft()
        XCTAssertNil(draft.habit)
        draft.name = "Morning run"
        XCTAssertNil(draft.habit, "a habit needs at least one step")
        draft.steps[0].title = "  Drink water  "
        XCTAssertEqual(draft.habit?.steps, [HabitStep(title: "Drink water", tiny: nil)])
    }

    func testDraftDropsBlankStepsAndCapsAtThree() {
        var draft = RTHabitDraft()
        draft.name = "Run"
        draft.steps = [.init(title: "a"), .init(title: ""), .init(title: "b", tiny: "tiny b"),
                       .init(title: "c"), .init(title: "d")]
        let habit = draft.habit
        XCTAssertEqual(habit?.steps.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(habit?.steps[1].tiny, "tiny b")
        XCTAssertEqual(habit?.steps.count, MemberHabit.maxSteps)
    }

    func testHabitRoundTripsThroughFirestoreMap() {
        let habit = MemberHabit(name: "Run", steps: [HabitStep(title: "Shoes", tiny: "Step outside")],
                                windowMinutes: 30, showSteps: false)
        let map = habit.firestoreData
        XCTAssertEqual(map["name"] as? String, "Run")
        XCTAssertEqual(map["windowMinutes"] as? Int, 30)
        XCTAssertEqual(map["showSteps"] as? Bool, false)
        let steps = map["steps"] as? [[String: Any]]
        XCTAssertEqual(steps?.first?["tiny"] as? String, "Step outside")
    }

    func testRoutineProgressParsesFromHistoryMap() {
        let routine = RoutineProgress(map: ["day": "2026-11-03", "done": [true, true, false], "tiny": false])
        XCTAssertEqual(routine?.summary, "2 of 3")
        XCTAssertEqual(routine?.isComplete, false)
        XCTAssertNil(RoutineProgress(map: ["done": [true]]), "a routine without its day is ignored")
    }

    func testTinyVersionCountsAsComplete() {
        let routine = RoutineProgress(day: "2026-11-03", done: [true, false, false], tiny: true)
        XCTAssertTrue(routine.isComplete)
        XCTAssertEqual(routine.summary, "Tiny version")
    }

    func testPerStepTinyVersionsParseAndCount() {
        let routine = RoutineProgress(map: ["day": "d", "done": [true, true, false], "tiny": false,
                                            "tinySteps": [false, true, false]])
        XCTAssertEqual(routine?.isTiny(0), false)
        XCTAssertEqual(routine?.isTiny(1), true)
        XCTAssertEqual(routine?.tinyCount, 1)
        XCTAssertEqual(routine?.isComplete, false, "a tiny step still has to be followed by the rest")
        XCTAssertEqual(RoutineProgress(map: ["day": "d", "done": [true], "tiny": false])?.isTiny(0), false,
                       "routines saved before per-step tiny versions read as full steps")
    }

    func testRoutineWindowClosesAtDeadline() {
        let deadline = Date(timeIntervalSince1970: 1_000_000)
        let routine = RoutineProgress(day: "d", done: [false], tiny: false, deadline: Timestamp(date: deadline))
        XCTAssertTrue(routine.isOpen(now: deadline.addingTimeInterval(-1)))
        XCTAssertFalse(routine.isOpen(now: deadline.addingTimeInterval(1)))
    }

    func testUnfinishedRoutineReadsAsMissedOnlyAfterTheWindow() {
        let deadline = Date(timeIntervalSince1970: 1_000_000)
        let routine = RoutineProgress(day: "d", done: [true, false, false], tiny: false, deadline: Timestamp(date: deadline))
        XCTAssertFalse(routine.isMissed(now: deadline.addingTimeInterval(-1)))
        XCTAssertEqual(routine.summary(now: deadline.addingTimeInterval(-1)), "1 of 3")
        XCTAssertTrue(routine.isMissed(now: deadline.addingTimeInterval(1)))
        XCTAssertEqual(routine.summary(now: deadline.addingTimeInterval(1)), "1 of 3 · 2 missed")
        let none = RoutineProgress(day: "d", done: [false, false, false], tiny: false, deadline: Timestamp(date: deadline))
        XCTAssertEqual(none.summary(now: deadline.addingTimeInterval(1)), "skipped · 0 of 3")
    }

    func testChecklistDraftDefaultsItsNameAndAllowsFiveItemsWithoutTinyVersions() {
        var draft = RTHabitDraft(checklist: true)
        draft.steps = (0..<7).map { RTHabitDraft.Step(title: "item \($0)", tiny: "tiny") }
        let plan = draft.habit
        XCTAssertEqual(plan?.name, MemberHabit.defaultChecklistName)
        XCTAssertEqual(plan?.steps.count, MemberHabit.maxChecklistItems)
        XCTAssertEqual(plan?.checklist, true)
        XCTAssertEqual(plan?.hasTinyVersion, false)
        XCTAssertNil(plan?.firestoreData["isChecklist"], "the checklist flag is local only")
    }
}
