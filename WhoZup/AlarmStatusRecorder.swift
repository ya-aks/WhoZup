//
//  AlarmStatusRecorder.swift
//  WhoZup
//
//  Converts AlarmKit alarm state transitions into `MemberAction`s and derives
//  the resulting `MemberStatus` via the pure `StatusDerivation` module.
//
//  AlarmKit doesn't deliver "the user tapped Stop/Snooze" callbacks the way
//  notification actions did; instead the system publishes alarm state through
//  `AlarmManager.alarmUpdates`. This recorder diffs consecutive snapshots:
//
//    - `.alerting` → gone            ⇒ the user stopped the alarm ⇒ dismiss
//    - `.alerting` → `.countdown`    ⇒ the user snoozed           ⇒ snooze
//    - `.countdown` → gone           ⇒ stopped during snooze      ⇒ dismiss
//
//  Persisting the derived status anywhere (backend, local store) is
//  explicitly out of scope here — a later issue wires this up for real.
//

import AlarmKit
import Combine
import Foundation
import os.log

/// A minimal, test-constructible snapshot of one alarm's state.
/// (`AlarmKit.Alarm` has no public initializer, so the transition-diffing
/// logic works on these instead and stays unit-testable.)
public struct AlarmSnapshot: Equatable, Sendable {
    public let id: UUID
    public let state: Alarm.State

    public init(id: UUID, state: Alarm.State) {
        self.id = id
        self.state = state
    }
}

/// One user-caused alarm transition: which alarm, and what action it implies.
public struct AlarmTransition: Equatable, Sendable {
    public let alarmID: UUID
    public let kind: MemberAction.Kind

    public init(alarmID: UUID, kind: MemberAction.Kind) {
        self.alarmID = alarmID
        self.kind = kind
    }
}

/// Pure mapping from consecutive alarm-state snapshots to the user actions
/// they imply. Kept separate from any AlarmKit runtime type so it's
/// trivially unit-testable.
public enum AlarmTransitionMapper {
    public static func transitions(
        from previous: [AlarmSnapshot],
        to current: [AlarmSnapshot]
    ) -> [AlarmTransition] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

        return previous.compactMap { old in
            let new = currentByID[old.id]
            switch (old.state, new?.state) {
            case (.alerting, nil), (.countdown, nil):
                return AlarmTransition(alarmID: old.id, kind: .dismiss)
            case (.alerting, .countdown):
                return AlarmTransition(alarmID: old.id, kind: .snooze)
            default:
                return nil
            }
        }
    }
}

/// Result of recording one alarm action: the `MemberAction` that was
/// recorded and the `MemberStatus` derived from it.
public struct AlarmActionResult: Equatable {
    public let action: MemberAction
    public let status: MemberStatus
}

/// Observes AlarmKit alarm updates, records the `MemberAction`s they imply,
/// derives a `MemberStatus` via `StatusDerivation`, logs it, and publishes
/// the latest result so SwiftUI can observe it.
///
/// Deliberately minimal — no persistence, no networking. This is the seam
/// where a future issue pushes the derived status to the backend.
@MainActor
public final class AlarmStatusRecorder: ObservableObject {
    /// The most recently derived result, if any. Observable by SwiftUI views.
    @Published public private(set) var lastResult: AlarmActionResult?

    /// Called whenever a status is derived from a real alarm action, with the
    /// originating alarm's ID. Lets a consumer (e.g. GroupRepository) persist
    /// the status to the right group. Not involved in unit tests (default nil).
    public var onRecorded: ((_ alarmID: UUID, _ result: AlarmActionResult) -> Void)?

    private var scheduledTimes: [UUID: Date] = [:]
    private var previousSnapshots: [AlarmSnapshot] = []
    private var observationTask: Task<Void, Never>?
    private let lateWindow: TimeInterval
    private let logger = Logger(subsystem: "com.whozup.WhoZup", category: "AlarmStatusRecorder")

    /// - Parameter lateWindow: Passed through to `StatusDerivation.status`.
    public init(lateWindow: TimeInterval = 10 * 60) {
        self.lateWindow = lateWindow
    }

    deinit {
        observationTask?.cancel()
    }

    /// Tells the recorder an alarm was scheduled for `scheduledTime`, so a
    /// later stop/snooze on it can be turned into a status. Call alongside
    /// `AlarmScheduler.scheduleAlarm`.
    public func registerScheduled(id: UUID, scheduledTime: Date) {
        scheduledTimes[id] = scheduledTime
    }

    /// Forgets an alarm — call before cancelling it programmatically so the
    /// cancellation isn't misread as the user dismissing the alarm.
    public func unregister(id: UUID) {
        scheduledTimes[id] = nil
        previousSnapshots.removeAll { $0.id == id }
    }

    /// Starts observing the real `AlarmManager.shared.alarmUpdates` stream.
    /// Call once, e.g. at app launch.
    public func startObserving() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            for await alarms in AlarmManager.shared.alarmUpdates {
                self?.ingest(snapshots: alarms.map { AlarmSnapshot(id: $0.id, state: $0.state) })
            }
        }
    }

    /// Diffs `snapshots` against the previously seen ones and records any
    /// user actions the transitions imply. Separated from `startObserving`
    /// so it can be unit-tested with synthetic snapshots.
    public func ingest(snapshots: [AlarmSnapshot], now: Date = Date()) {
        let transitions = AlarmTransitionMapper.transitions(from: previousSnapshots, to: snapshots)
        previousSnapshots = snapshots

        for transition in transitions {
            record(kind: transition.kind, alarmID: transition.alarmID, now: now)
        }
    }

    /// Records one action against a registered alarm and derives the status.
    ///
    /// - Returns: The derived result, or `nil` if the alarm isn't registered
    ///   (e.g. it was cancelled programmatically, or scheduled by an earlier
    ///   app run this recorder doesn't know about).
    @discardableResult
    public func record(
        kind: MemberAction.Kind,
        alarmID: UUID,
        now: Date = Date()
    ) -> AlarmActionResult? {
        guard let scheduledTime = scheduledTimes[alarmID] else {
            return nil
        }

        let action = MemberAction(kind: kind, timestamp: now)
        let status = StatusDerivation.status(
            scheduledTime: scheduledTime,
            actions: [action],
            now: now,
            lateWindow: lateWindow
        )

        // A dismiss ends the alarm's lifecycle; a snoozed alarm will re-alert
        // and its eventual dismiss should still derive against the original
        // scheduled time.
        if kind == .dismiss {
            scheduledTimes[alarmID] = nil
        }

        let result = AlarmActionResult(action: action, status: status)
        lastResult = result
        onRecorded?(alarmID, result)
        logger.log("Alarm action \(kind == .dismiss ? "dismiss" : "snooze", privacy: .public) -> status \(String(describing: status), privacy: .public)")
        return result
    }
}
