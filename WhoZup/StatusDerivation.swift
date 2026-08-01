//
//  StatusDerivation.swift
//  WhoZup
//
//  Pure, UI-decoupled status-derivation logic shared by group types
//  (Accountability, Shared, and later Event/Coordination groups).
//
//  No UIKit/SwiftUI/UNUserNotificationCenter/networking dependencies.
//

import Foundation

/// A member's derived status relative to a scheduled time (e.g. an alarm).
///
/// Kept generic enough to be reused by group types beyond Accountability/Shared
/// (e.g. Event/Coordination groups may map their own response vocabulary onto
/// `respondedEarly`/`respondedLate`/`pending`, or introduce their own status
/// enum that composes with `MemberAction` below).
public enum MemberStatus: Equatable, Hashable, Sendable {
    /// The member dismissed in time (e.g. alarm dismissed → "Woke Up").
    case respondedOnTime
    /// The member snoozed (e.g. alarm snoozed → "Snoozed").
    case snoozed
    /// No action was taken within the configured window after the scheduled time.
    case silentLate
    /// The window has not yet elapsed and no action has been taken.
    case pending
}

/// A single device action taken by a member, with the time it occurred.
public struct MemberAction: Equatable, Hashable, Sendable {
    /// The kind of action taken.
    public enum Kind: Equatable, Hashable, Sendable {
        case dismiss
        case snooze
    }

    public let kind: Kind
    public let timestamp: Date

    public init(kind: Kind, timestamp: Date) {
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// Pure status-derivation logic.
///
/// `status` is a pure function of (scheduled time, actions, current time, threshold) -> `MemberStatus`.
/// No hidden state, no singletons, no I/O — fully unit-testable and reusable across group types.
public enum StatusDerivation {

    /// Derives a member's current status.
    ///
    /// - Parameters:
    ///   - scheduledTime: The alarm/event time the status is being derived relative to.
    ///   - actions: The sequence of device actions taken by the member, in any order.
    ///     If multiple actions are present, the most recent action (by timestamp) determines
    ///     the status — e.g. a snooze followed by a later dismiss resolves to `respondedOnTime`.
    ///   - now: The current time to evaluate against (injected, not read from `Date()`, to keep
    ///     this pure and deterministic for tests).
    ///   - lateWindow: The configurable window after `scheduledTime` within which an action
    ///     must occur to avoid `silentLate`. An action exactly at the boundary
    ///     (`scheduledTime + lateWindow`) still counts as in-window.
    /// - Returns: The derived `MemberStatus`.
    public static func status(
        scheduledTime: Date,
        actions: [MemberAction],
        now: Date,
        lateWindow: TimeInterval
    ) -> MemberStatus {
        let deadline = scheduledTime.addingTimeInterval(lateWindow)

        // Only actions occurring at-or-after the scheduled time and at-or-before the
        // deadline count toward the derived status; anything outside that window is ignored.
        let inWindowActions = actions.filter { $0.timestamp >= scheduledTime && $0.timestamp <= deadline }

        if let latest = inWindowActions.max(by: { $0.timestamp < $1.timestamp }) {
            switch latest.kind {
            case .dismiss:
                return .respondedOnTime
            case .snooze:
                return .snoozed
            }
        }

        // No qualifying action. If the window has already elapsed, the member went silent.
        if now > deadline {
            return .silentLate
        }

        return .pending
    }
}
