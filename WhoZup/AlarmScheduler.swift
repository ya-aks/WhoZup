//
//  AlarmScheduler.swift
//  WhoZup
//
//  Local, on-device alarm scheduling via AlarmKit (iOS 26+).
//
//  AlarmKit alarms are real system alarms: they break through silent mode
//  and Focus, present a system alert UI with a Stop button, and support a
//  native snooze via the `.countdown` secondary-button behavior — none of
//  which UNUserNotificationCenter local notifications can do without
//  special entitlements. Requires `NSAlarmKitUsageDescription` in the
//  app's Info.plist (set via build settings).
//
//  This is purely client-side: no networking, no backend. Converting alarm
//  state changes (stopped/snoozed) into a `MemberAction` and deriving a
//  `MemberStatus` via `StatusDerivation` lives in `AlarmStatusRecorder`.
//

import AlarmKit
import Foundation
import SwiftUI

/// Metadata attached to every WhoZup alarm. Carried through AlarmKit so a
/// future Live Activity widget extension can render the scheduled time.
public struct WhoZupAlarmMetadata: AlarmMetadata {
    public let scheduledTime: Date

    public init(scheduledTime: Date) {
        self.scheduledTime = scheduledTime
    }
}

/// Narrow protocol over the pieces of `AlarmManager` that `AlarmScheduler`
/// needs. Lets scheduling logic be unit-tested with a fake, without touching
/// the real alarm manager (which prompts for authorization and schedules
/// real system alarms).
@MainActor
public protocol AlarmScheduling: AnyObject {
    var authorizationState: AlarmManager.AuthorizationState { get }
    /// Alarms currently known to the system, including ones scheduled by an
    /// earlier run of the app. Reconciliation depends on this: AlarmKit alarms
    /// outlive the process, so in-memory bookkeeping alone can't tell what
    /// already exists.
    var alarms: [Alarm] { get throws }
    func requestAuthorization() async throws -> AlarmManager.AuthorizationState
    func scheduleAlarm(id: UUID, configuration: AlarmManager.AlarmConfiguration<WhoZupAlarmMetadata>) async throws
    func stop(id: UUID) throws
    func countdown(id: UUID) throws
    func cancel(id: UUID) throws
}

extension AlarmManager: AlarmScheduling {
    public func scheduleAlarm(id: UUID, configuration: AlarmManager.AlarmConfiguration<WhoZupAlarmMetadata>) async throws {
        _ = try await schedule(id: id, configuration: configuration)
    }
}

/// Schedules local, on-device alarms via AlarmKit.
///
/// Depends on `AlarmScheduling` rather than the concrete `AlarmManager`
/// singleton, so it can be unit-tested with a fake.
@MainActor
public final class AlarmScheduler {
    private let manager: AlarmScheduling
    private let snoozeInterval: TimeInterval

    /// How long the native Snooze countdown runs before the alarm re-alerts.
    public static let defaultSnoozeInterval: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - manager: The alarm manager to schedule against. Defaults to the
    ///     real `AlarmManager.shared`; inject a fake in tests.
    ///   - snoozeInterval: How long a snooze countdown runs before the alarm
    ///     re-alerts. Defaults to 5 minutes.
    public init(
        manager: AlarmScheduling = AlarmManager.shared,
        snoozeInterval: TimeInterval = AlarmScheduler.defaultSnoozeInterval
    ) {
        self.manager = manager
        self.snoozeInterval = snoozeInterval
    }

    /// Ensures AlarmKit authorization, prompting the user if it hasn't been
    /// decided yet. Returns whether alarms may be scheduled.
    public func ensureAuthorized() async throws -> Bool {
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            return try await manager.requestAuthorization() == .authorized
        @unknown default:
            return false
        }
    }

    /// Schedules an alarm to fire at `date`, with a system Stop button and a
    /// Snooze button that starts a `snoozeInterval` countdown before
    /// re-alerting.
    public func scheduleAlarm(id: UUID, date: Date, label: String = "Alarm") async throws {
        let configuration = Self.makeConfiguration(
            id: id,
            date: date,
            label: label,
            snoozeInterval: snoozeInterval
        )
        try await manager.scheduleAlarm(id: id, configuration: configuration)
    }

    /// Schedules a *repeating* alarm at `time` ("HH:mm") on the given weekdays
    /// (`1=Sunday … 7=Saturday`; empty means every day), using AlarmKit's native
    /// weekly recurrence so it keeps ringing without the app being reopened.
    public func scheduleAlarm(id: UUID, time: String, days: [Int], label: String = "Alarm") async throws {
        let configuration = Self.makeConfiguration(
            id: id,
            time: time,
            days: days,
            label: label,
            snoozeInterval: snoozeInterval
        )
        try await manager.scheduleAlarm(id: id, configuration: configuration)
    }

    /// Cancels a scheduled (not-yet-fired) alarm.
    public func cancelAlarm(id: UUID) throws {
        try manager.cancel(id: id)
    }

    /// One alarm that currently exists on the system, reduced to the two facts
    /// reconciliation needs: which alarm, and when it fires.
    public struct ExistingAlarm: Equatable, Sendable {
        public let id: UUID
        public let date: Date

        public init(id: UUID, date: Date) {
            self.id = id
            self.date = date
        }
    }

    /// One alarm the system currently holds, reduced to what reconciliation
    /// needs: which alarm and the local "HH:mm" it fires at. Covers both the
    /// repeating `.relative` alarms this build schedules and any legacy
    /// `.fixed` alarms left by an earlier build (so they can be adopted/replaced).
    public struct ExistingSlot: Equatable, Sendable {
        public let id: UUID
        /// The reconcile key: "HH:mm" for a repeating alarm, "HH:mm#once" for a
        /// single one (a fixed-date alarm). Matches the keys `RTAlarmSync` uses.
        public let key: String
        public init(id: UUID, key: String) { self.id = id; self.key = key }
    }

    /// Every scheduled alarm the system holds, as (id, key). A relative
    /// (repeating) alarm keys on its time; a fixed (single) alarm keys on its
    /// time plus "#once", so the two never collide at the same clock time.
    public func existingSlots() throws -> [ExistingSlot] {
        try manager.alarms.compactMap { alarm in
            switch alarm.schedule {
            case .relative(let rel):
                let time = String(format: "%02d:%02d", rel.time.hour, rel.time.minute)
                return ExistingSlot(id: alarm.id, key: time)
            case .fixed(let date):
                return ExistingSlot(id: alarm.id, key: "\(RTAlarmTime.string(from: date))#once")
            @unknown default:
                return nil
            }
        }
    }

    /// Every fixed-date alarm the system currently holds, including ones this
    /// process didn't schedule. Alarms without a fixed date (relative or
    /// unscheduled) are omitted — nothing here schedules those.
    public func existingAlarms() throws -> [ExistingAlarm] {
        try manager.alarms.compactMap { alarm in
            guard case .fixed(let date) = alarm.schedule else { return nil }
            return ExistingAlarm(id: alarm.id, date: date)
        }
    }

    // MARK: - Configuration building

    /// Builds the full AlarmKit configuration for an alarm at `date`.
    /// The presentation and countdown pieces are exposed separately below so
    /// they can be unit-tested (AlarmConfiguration itself is opaque).
    static func makeConfiguration(
        id: UUID,
        date: Date,
        label: String,
        snoozeInterval: TimeInterval
    ) -> AlarmManager.AlarmConfiguration<WhoZupAlarmMetadata> {
        let attributes = AlarmAttributes<WhoZupAlarmMetadata>(
            presentation: makePresentation(label: label),
            metadata: WhoZupAlarmMetadata(scheduledTime: date),
            tintColor: .orange
        )
        return AlarmManager.AlarmConfiguration(
            countdownDuration: makeCountdownDuration(snoozeInterval: snoozeInterval),
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: StopAlarmIntent(alarmID: id),
            secondaryIntent: SnoozeAlarmIntent(alarmID: id)
        )
    }

    /// Builds a repeating configuration firing at `time` ("HH:mm") on the given
    /// weekdays (empty means every day), using AlarmKit weekly recurrence.
    static func makeConfiguration(
        id: UUID,
        time: String,
        days: [Int],
        label: String,
        snoozeInterval: TimeInterval
    ) -> AlarmManager.AlarmConfiguration<WhoZupAlarmMetadata> {
        let parts = time.split(separator: ":")
        let hour = Int(parts.first ?? "6") ?? 6
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let weekdays = (days.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : days).map(localeWeekday)

        let schedule = Alarm.Schedule.relative(
            Alarm.Schedule.Relative(
                time: Alarm.Schedule.Relative.Time(hour: hour, minute: minute),
                repeats: .weekly(weekdays)
            )
        )
        let attributes = AlarmAttributes<WhoZupAlarmMetadata>(
            presentation: makePresentation(label: label),
            metadata: WhoZupAlarmMetadata(scheduledTime: RTAlarmTime.nextDate(for: time)),
            tintColor: .orange
        )
        return AlarmManager.AlarmConfiguration(
            countdownDuration: makeCountdownDuration(snoozeInterval: snoozeInterval),
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopAlarmIntent(alarmID: id),
            secondaryIntent: SnoozeAlarmIntent(alarmID: id)
        )
    }

    /// Maps `1=Sunday … 7=Saturday` to AlarmKit's `Locale.Weekday`.
    static func localeWeekday(_ n: Int) -> Locale.Weekday {
        switch n {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        default: return .saturday
        }
    }

    /// The alert/countdown presentation for a WhoZup alarm: a system Stop
    /// button plus a Snooze secondary button whose `.countdown` behavior
    /// makes the system run the snooze countdown natively.
    static func makePresentation(label: String) -> AlarmPresentation {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource("\(label)"),
            secondaryButton: AlarmButton(
                text: "Snooze",
                textColor: .white,
                systemImageName: "zzz"
            ),
            secondaryButtonBehavior: .countdown
        )
        let countdown = AlarmPresentation.Countdown(
            title: LocalizedStringResource("Snoozed — \(label)")
        )
        return AlarmPresentation(alert: alert, countdown: countdown)
    }

    /// Only `postAlert` is set: there is no pre-alarm countdown, and a snooze
    /// re-alerts after `snoozeInterval`.
    static func makeCountdownDuration(snoozeInterval: TimeInterval) -> Alarm.CountdownDuration {
        Alarm.CountdownDuration(preAlert: nil, postAlert: snoozeInterval)
    }
}
