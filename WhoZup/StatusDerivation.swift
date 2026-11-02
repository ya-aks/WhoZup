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
    /// The member responded (dismissed or snoozed), but only after the late
    /// window had elapsed — late, yet not silent.
    case respondedLate
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

        // A response is any action at-or-after the scheduled time; anything before
        // the alarm even fired is unrelated and ignored. The most recent one wins.
        let responses = actions.filter { $0.timestamp >= scheduledTime }

        if let latest = responses.max(by: { $0.timestamp < $1.timestamp }) {
            // Responding after the deadline is late — whether a dismiss or a
            // snooze. The member engaged, just too late to count as on time.
            if latest.timestamp > deadline {
                return .respondedLate
            }
            switch latest.kind {
            case .dismiss:
                return .respondedOnTime
            case .snooze:
                return .snoozed
            }
        }

        // No response at all. If the window has already elapsed, the member went silent.
        if now > deadline {
            return .silentLate
        }

        return .pending
    }
}

/// A single scheduled occurrence of a recurring alarm whose late deadline has
/// already elapsed.
public struct MissedOccurrence: Equatable, Hashable, Sendable {
    /// "yyyy-MM-dd" key for the day the alarm was scheduled, matching the id
    /// used under a member's `history` subcollection.
    public let dayKey: String
    /// The absolute instant the alarm was scheduled to fire.
    public let fireDate: Date

    public init(dayKey: String, fireDate: Date) {
        self.dayKey = dayKey
        self.fireDate = fireDate
    }
}

/// Pure logic for finding *skipped* alarms — recurring alarm slots whose late
/// deadline has passed with no response, e.g. because the device was switched
/// off and the ring UI never ran. This is the missing counterpart to
/// `StatusDerivation`, which only ever runs in reaction to a real action.
///
/// One-time (`once`) alarms are deliberately out of scope: their fire date
/// isn't recoverable from a bare "HH:mm" string, so a past occurrence can't be
/// reconstructed without risking a false "late".
public enum MissedAlarm {
    /// The default late window, mirroring `AlarmStatusRecorder`/`AlarmActionIntents`.
    public static let defaultLateWindow: TimeInterval = 15 * 60

    /// Occurrences of the alarm at `time` on `days`, within the last
    /// `lookbackDays` days (inclusive of today, offset 0), whose deadline
    /// (`fire + lateWindow`) has already elapsed as of `now`. Most recent first.
    ///
    /// - Parameters:
    ///   - time: 24-hour "HH:mm" wall-clock time, read in `calendar`'s zone.
    ///   - days: Weekdays the alarm rings (1=Sun … 7=Sat, matching `Calendar`).
    ///     Empty means every day.
    ///   - now: The current instant to evaluate against (injected for testing).
    ///   - lookbackDays: How many days before today to also consider. `0` means
    ///     today only — the right choice for the live roster, which only ever
    ///     shows the current day.
    ///   - lateWindow: Grace period after the fire time before a no-response slot
    ///     counts as silent-late.
    ///   - notBefore: The instant the alarm actually started applying to this
    ///     member — when they set/changed it, or joined. An occurrence whose fire
    ///     time is before this is ignored: you can't miss an alarm that fired
    ///     before you had it. Nil means "always applied" (no floor).
    public static func missedOccurrences(
        time: String,
        days: [Int],
        now: Date = Date(),
        lookbackDays: Int,
        lateWindow: TimeInterval = defaultLateWindow,
        notBefore: Date? = nil,
        calendar: Calendar = .current
    ) -> [MissedOccurrence] {
        let parts = time.split(separator: ":")
        guard let hour = parts.first.flatMap({ Int($0) }) else { return [] }
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var result: [MissedOccurrence] = []
        for offset in 0...max(0, lookbackDays) {
            guard let dayDate = calendar.date(byAdding: .day, value: -offset, to: now),
                  let fireDate = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: dayDate
                  )
            else { continue }

            // Respect which weekdays the alarm actually rings.
            let weekday = calendar.component(.weekday, from: fireDate)
            if !days.isEmpty, !days.contains(weekday) { continue }

            // An alarm set for later today (or whose time already passed when it
            // was set) hasn't fired for this member yet — don't count it missed.
            if let notBefore, fireDate < notBefore { continue }

            let deadline = fireDate.addingTimeInterval(lateWindow)
            guard now > deadline else { continue }

            result.append(MissedOccurrence(dayKey: dayFormatter.string(from: fireDate), fireDate: fireDate))
        }
        return result
    }

    /// The most recent occurrence of the alarm at `time` on `days` that fired at
    /// or before `now`, searching back up to `lookbackDays`. `nil` if none falls
    /// in range.
    ///
    /// This is what a background stop/snooze must derive against: a repeating
    /// AlarmKit alarm keeps firing on later days with no reschedule, so the fire
    /// time captured when the alarm was last reconciled goes stale. Deriving a
    /// day-2 wake-up against day-1's time would misread an on-time dismiss as
    /// `respondedLate`. Recomputing the actual occurrence keeps the outcome right.
    public static func mostRecentFire(
        time: String,
        days: [Int],
        now: Date = Date(),
        lookbackDays: Int = 7,
        calendar: Calendar = .current
    ) -> Date? {
        let parts = time.split(separator: ":")
        guard let hour = parts.first.flatMap({ Int($0) }) else { return nil }
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0

        for offset in 0...max(0, lookbackDays) {
            guard let dayDate = calendar.date(byAdding: .day, value: -offset, to: now),
                  let fireDate = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: dayDate
                  )
            else { continue }
            // Skip a fire still in the future (today's alarm hasn't rung yet).
            if fireDate > now { continue }
            let weekday = calendar.component(.weekday, from: fireDate)
            if !days.isEmpty, !days.contains(weekday) { continue }
            return fireDate
        }
        return nil
    }

    /// Whether *today's* scheduled occurrence has passed its deadline with no
    /// response — the check the live roster uses to show a member as silent-late
    /// before their own device has written the status.
    public static func isTodayMissed(
        time: String,
        days: [Int],
        now: Date = Date(),
        lateWindow: TimeInterval = defaultLateWindow,
        notBefore: Date? = nil,
        calendar: Calendar = .current
    ) -> Bool {
        !missedOccurrences(
            time: time, days: days, now: now,
            lookbackDays: 0, lateWindow: lateWindow, notBefore: notBefore, calendar: calendar
        ).isEmpty
    }
}
