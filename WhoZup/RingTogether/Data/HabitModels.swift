//
//  HabitModels.swift
//  WhoZup
//
//  Personal habits on Check-ins groups.
//
//  A habit belongs to one member of one group, like their alarm time: it lives
//  on `groups/{id}/members/{uid}.habit`, and a group can mix members with and
//  without one. Each day the member's alarm is stopped on time — on the first
//  ring, no snooze — the routine for that day opens and its progress is merged
//  into two docs the app already reads:
//
//    - `groups/{id}/statuses/{uid}.routine` — today's live progress (roster)
//    - `groups/{id}/members/{uid}/history/{day}.routine` — the Rise Report
//
//  Field names here are the contract with Android (`data/HabitModels.kt`).
//

import FirebaseFirestore
import Foundation

/// One step of a habit routine, with an optional smaller fallback.
struct HabitStep: Codable, Hashable {
    var title: String
    /// "Tiny version" — what still counts on a hard day (e.g. "step outside").
    var tiny: String?
}

/// A member's habit in one group.
struct MemberHabit: Codable, Hashable {
    /// Most a routine may hold: small and specific beats ambitious.
    static let maxSteps = 3
    /// The routine stays open between 1 and 59 minutes after the alarm stops.
    static let windowRange = 1...59

    var name: String
    var steps: [HabitStep]
    /// How long after the alarm stops the routine stays open.
    var windowMinutes: Int
    /// Whether other members see the habit and step names, or only "2 of 3".
    var showSteps: Bool

    /// Firestore map form, for merge writes.
    var firestoreData: [String: Any] {
        [
            "name": name,
            "steps": steps.map { step -> [String: Any] in
                var map: [String: Any] = ["title": step.title]
                if let tiny = step.tiny, !tiny.isEmpty { map["tiny"] = tiny }
                return map
            },
            "windowMinutes": windowMinutes,
            "showSteps": showSteps,
        ]
    }

    /// Whether any step offers a tiny version.
    var hasTinyVersion: Bool { steps.contains { !($0.tiny ?? "").isEmpty } }
}

/// One day's routine progress.
struct RoutineProgress: Codable, Hashable {
    /// "yyyy-MM-dd" of the alarm this routine follows.
    var day: String
    var done: [Bool]
    /// Finished with the tiny version instead of the full steps (whole
    /// routine — kept for routines saved before per-step tiny versions).
    var tiny: Bool
    /// Per step: done with its tiny version rather than the full step.
    var tinySteps: [Bool]?
    var startedAt: Timestamp?
    var deadline: Timestamp?
    var completedAt: Timestamp?

    init(day: String, done: [Bool], tiny: Bool, tinySteps: [Bool]? = nil, startedAt: Timestamp? = nil,
         deadline: Timestamp? = nil, completedAt: Timestamp? = nil) {
        self.day = day
        self.done = done
        self.tiny = tiny
        self.tinySteps = tinySteps
        self.startedAt = startedAt
        self.deadline = deadline
        self.completedAt = completedAt
    }

    /// Reads the `routine` map off a raw history/status document.
    init?(map: Any?) {
        guard let map = map as? [String: Any], let day = map["day"] as? String,
              let done = map["done"] as? [Bool] else { return nil }
        self.init(day: day, done: done, tiny: map["tiny"] as? Bool ?? false,
                  tinySteps: map["tinySteps"] as? [Bool],
                  startedAt: map["startedAt"] as? Timestamp,
                  deadline: map["deadline"] as? Timestamp,
                  completedAt: map["completedAt"] as? Timestamp)
    }

    var doneCount: Int { done.filter { $0 }.count }
    var total: Int { done.count }
    var isComplete: Bool { tiny || (total > 0 && doneCount == total) }

    /// Still open: not finished and the window hasn't closed.
    func isOpen(now: Date = Date()) -> Bool {
        guard !isComplete else { return false }
        guard let deadline = deadline?.dateValue() else { return true }
        return now <= deadline
    }

    var firestoreData: [String: Any] {
        var map: [String: Any] = ["day": day, "done": done, "tiny": tiny]
        if let tinySteps { map["tinySteps"] = tinySteps }
        if let startedAt { map["startedAt"] = startedAt }
        if let deadline { map["deadline"] = deadline }
        map["completedAt"] = completedAt ?? NSNull()
        return map
    }

    /// Whether step `i` was done with its tiny version.
    func isTiny(_ i: Int) -> Bool { tiny || (tinySteps?.indices.contains(i) == true && tinySteps![i]) }
    var tinyCount: Int { (tinySteps ?? []).filter { $0 }.count }

    /// The short label the roster and reports show.
    var summary: String {
        if tiny { return "Tiny version" }
        if isComplete { return "Done" }
        return "\(doneCount) of \(total)"
    }
}
