//
//  RoutineActivity.swift
//  WhoZup (app + WhoZupWidgets)
//
//  Shared between the app and the widget extension: the Live Activity that
//  shows a habit routine on the lock screen after the alarm is stopped, and
//  the intent behind its one "Done" button.
//
//  Per Apple's Live Activity guidance the card shows one step at a time with a
//  single control. The intent is a `LiveActivityIntent`, so the system runs it
//  in the app's process (where the routine is persisted and synced), never in
//  the extension; on a locked phone it runs after Face ID, as documented.
//

import ActivityKit
import AppIntents
import Foundation

nonisolated struct RoutineActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var done: [Bool]
        var tiny: Bool
        /// Per step: done with its tiny version.
        var tinySteps: [Bool]? = nil

        func isTiny(_ i: Int) -> Bool { tiny || (tinySteps?.indices.contains(i) == true && tinySteps![i]) }

        var doneCount: Int { done.filter { $0 }.count }
        var isComplete: Bool { tiny || (!done.isEmpty && !done.contains(false)) }
        /// The first step still to do, if any.
        var nextIndex: Int? { done.firstIndex(of: false) }
    }

    var groupId: String
    var groupName: String
    var habitName: String
    var steps: [String]
    /// Each step's tiny version ("" when it has none).
    var tinies: [String]? = nil
    var deadline: Date

    func tinyVersion(of i: Int) -> String? {
        guard let t = tinies, t.indices.contains(i), !t[i].isEmpty else { return nil }
        return t[i]
    }
}

/// Marks one step of the running routine done, from the Live Activity.
struct RoutineStepDoneIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark Routine Step Done"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Group ID") var groupId: String
    @Parameter(title: "Step") var step: Int
    /// Done with the step's tiny version instead of the full step.
    @Parameter(title: "Tiny version") var tiny: Bool

    init() {}
    init(groupId: String, step: Int, tiny: Bool = false) {
        self.groupId = groupId
        self.step = step
        self.tiny = tiny
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await RoutineCoordinator.shared.completeStep(step, tiny: tiny, groupId: groupId)
        #endif
        return .result()
    }
}

/// The deep link the Live Activity's "Open routine" uses.
nonisolated enum RoutineLink {
    static let url = URL(string: "whozup://routine")!
    static func matches(_ url: URL) -> Bool { url.scheme == "whozup" && url.host == "routine" }
}
