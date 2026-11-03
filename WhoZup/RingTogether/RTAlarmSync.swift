//
//  RTAlarmSync.swift
//  WhoZup
//
//  Keeps local AlarmKit alarms in sync with the user's alarm-type groups. When
//  a group is created/joined or its wake-up time changes (locally or via a live
//  update from another member/admin), this reconciles the on-device alarms:
//  scheduling new ones, rescheduling changed ones, and cancelling removed ones.
//  This is what makes "my alarm is set straight away" and "edits propagate to
//  everyone" work — each device reconciles from live Firestore data.
//

import ActivityKit
import CryptoKit
import Foundation

/// Time helpers for alarm times stored as 24-hour "HH:mm" strings.
enum RTAlarmTime {
    /// Formats a picked time as 24-hour "HH:mm" (e.g. "06:30", "19:00").
    static func string(from date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 6, comps.minute ?? 0)
    }

    private static func components(from time: String) -> (hour: Int, minute: Int) {
        let parts = time.split(separator: ":")
        return (Int(parts.first ?? "6") ?? 6, parts.count > 1 ? (Int(parts[1]) ?? 0) : 0)
    }

    /// Next future occurrence of a 24-hour "HH:mm" time string, in this
    /// device's current time zone.
    static func nextDate(for time: String) -> Date {
        nextDate(for: time, in: .current)
    }

    /// Next future occurrence of "HH:mm" **as read in `zone`**, as an absolute
    /// instant. This is what turns an admin's wall-clock choice into a real
    /// moment that members elsewhere can convert into their own local time.
    static func nextDate(for time: String, in zone: TimeZone) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = zone
        let c = components(from: time)
        var comps = DateComponents()
        comps.hour = c.hour
        comps.minute = c.minute
        return calendar.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(60)
    }

    /// Converts "HH:mm" as read in `zone` into the equivalent wall-clock time
    /// on this device. A 06:30 alarm set in Asia/Kolkata reads as 01:00 to a
    /// member in Europe/London. Identity when the zones already agree.
    static func localTime(of time: String, in zone: TimeZone) -> String {
        guard zone.identifier != TimeZone.current.identifier else { return time }
        return string(from: nextDate(for: time, in: zone))
    }

    /// A `Date` for the picker's initial value from a stored "HH:mm" string.
    static func date(from time: String) -> Date {
        let c = components(from: time)
        var comps = DateComponents()
        comps.hour = c.hour
        comps.minute = c.minute
        return Calendar.current.date(from: comps) ?? Date()
    }

    /// Human display like "6:30 AM" / "7:00 PM" from a stored "HH:mm" string.
    static func display(_ time: String) -> String {
        let c = components(from: time)
        let isAM = c.hour < 12
        var h = c.hour % 12
        if h == 0 { h = 12 }
        return String(format: "%d:%02d %@", h, c.minute, isAM ? "AM" : "PM")
    }
}

@MainActor
final class RTAlarmSync {
    private let scheduler: AlarmScheduler
    private let recorder: AlarmStatusRecorder
    private weak var repository: GroupRepository?

    /// "HH:mm" -> the label the alarm for that time was last scheduled with.
    ///
    /// Only the label needs remembering: an alarm's *identity* is derived from
    /// its time (see `alarmID(forTime:)`), and what actually exists is read
    /// back from the system, so this map is a cache rather than the source of
    /// truth. It being empty after a cold start is harmless.
    private var scheduledLabels: [String: String] = [:]
    /// "HH:mm" -> the weekday set the alarm for that time was last scheduled
    /// with, so a change to which days ring re-triggers a reschedule.
    private var scheduledDays: [String: [Int]] = [:]
    /// "HH:mm" -> whether that alarm's Stop opens the app (habit routine with
    /// Live Activities off), so flipping it reschedules the alarm.
    private var scheduledOpensApp: [String: Bool] = [:]
    private var authorized: Bool?

    init(scheduler: AlarmScheduler, recorder: AlarmStatusRecorder, repository: GroupRepository) {
        self.scheduler = scheduler
        self.recorder = recorder
        self.repository = repository
    }

    /// A signature of the current desired alarms; when it changes, reconcile.
    ///
    /// Includes the device's time zone: `alarm` is already local wall-clock, so
    /// flying to another zone changes it and the signature moves on its own —
    /// but a zone change that leaves the local time identical (a pure DST
    /// shift, say) still needs the underlying absolute instant recomputed.
    static func signature(for groups: [RTGroup], timeZone: TimeZone = .current) -> String {
        let alarms = groups
            .filter { ($0.type == .accountability || $0.type == .shared) && !$0.alarm.isEmpty }
            .map { group -> String in
                // Your habit too: a new or edited habit must reach the alarm record.
                let habit = group.roster.first { $0.isYou }?.habit.map {
                    "\($0.name)/\($0.steps.map(\.title).joined(separator: ","))/\($0.windowMinutes)"
                } ?? ""
                return "\(group.id):\(group.alarm):\(group.alarmDays.map(String.init).joined(separator: "-")):\(group.alarmOnce ? "1" : "0"):\(habit)"
            }
            .sorted()
            .joined(separator: "|")
        return "\(timeZone.identifier)#\(alarms)"
    }

    /// The reconcile key for a group's alarm: the plain time for a repeating
    /// alarm, or "HH:mm#once" for a single (non-recurring) shared alarm — which
    /// keeps a one-time alarm from colliding with a repeating one at the same
    /// clock time.
    static func slotKey(for group: RTGroup) -> String {
        (group.type == .shared && group.alarmOnce) ? "\(group.alarm)#once" : group.alarm
    }

    /// The weekdays a *repeating* alarm at `time` should ring, unioned across
    /// every repeating group that wants that time. If any rings every day (empty
    /// day set), the union is every day too. Returns `[]` for "every day".
    /// One-time groups are excluded — they don't recur.
    static func unionDays(forTime time: String, in groups: [RTGroup]) -> [Int] {
        let atTime = groups.filter {
            ($0.type == .accountability || $0.type == .shared) && $0.alarm == time && !$0.alarmOnce
        }
        if atTime.contains(where: { $0.alarmDays.isEmpty }) { return [] }
        var set = Set<Int>()
        atTime.forEach { set.formUnion($0.alarmDays) }
        return set.sorted()
    }

    /// The alarms that *should* exist, keyed by slot (see `slotKey`): repeating
    /// alarms collapse per distinct time, while a single shared alarm gets its
    /// own "#once" slot. Group ids are sorted for stable output.
    static func desiredAlarms(for groups: [RTGroup]) -> [String: [String]] {
        var desired: [String: [String]] = [:]
        for group in groups where group.type == .accountability || group.type == .shared {
            guard !group.alarm.isEmpty else { continue }
            desired[slotKey(for: group), default: []].append(group.id)
        }
        return desired.mapValues { $0.sorted() }
    }

    /// The stable identity of "the alarm at `time`".
    ///
    /// Derived from the time rather than random, so the 06:30 alarm is the same
    /// alarm on every launch. That is what makes reconciliation idempotent:
    /// rescheduling replaces the existing alarm instead of adding a second one,
    /// and an alarm left behind by a previous run can still be recognised and
    /// cancelled. Also acts as a marker — an alarm whose id doesn't match the
    /// id derived from its own fire time wasn't scheduled by this sync, so it's
    /// left alone.
    static func alarmID(forTime time: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("com.whozup.alarm.\(time)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // UUID version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Reconciles on-device alarms to match the user's alarm-type groups.
    ///
    /// One alarm per distinct wake-up time, not one per group: several groups
    /// wanting 06:30 get a single 06:30 alarm covering all of them, and the one
    /// dismiss or snooze fans out to every group behind it.
    ///
    /// Reconciles against what the *system* actually holds, not against
    /// in-memory bookkeeping, so alarms scheduled by a previous launch are
    /// adopted rather than duplicated, and alarms for groups deleted while the
    /// app was closed still get cleaned up.
    func reconcile() async {
        guard let repository else { return }

        let desired = Self.desiredAlarms(for: repository.groups)
        let existing = (try? scheduler.existingSlots()) ?? []

        // Our alarms that currently exist, by time. An alarm counts as ours
        // only if its id matches the one derived from its own fire time, which
        // leaves anything scheduled elsewhere (e.g. the debug alarm section)
        // untouched.
        var live: [String: UUID] = [:]
        for slot in existing {
            guard Self.alarmID(forTime: slot.key) == slot.id else { continue }
            live[slot.key] = slot.id
        }

        // Cancel alarms for slots nobody wants any more — a group was deleted,
        // left, retimed, or switched between repeating and single.
        for (key, id) in live where desired[key] == nil {
            cancel(id, repository: repository)
        }
        live = live.filter { desired[$0.key] != nil }
        scheduledLabels = scheduledLabels.filter { desired[$0.key] != nil }
        scheduledDays = scheduledDays.filter { desired[$0.key] != nil }
        scheduledOpensApp = scheduledOpensApp.filter { desired[$0.key] != nil }

        // Habits ride along with the alarm records so a Stop in a cold
        // background launch can open the routine.
        let habits = repository.myHabitsByGroup()
        let liveActivitiesOn = ActivityAuthorizationInfo().areActivitiesEnabled

        guard !desired.isEmpty else { await AlarmCheckInNotifier.refresh(); return }
        guard await ensureAuthorized() else { return }

        for (key, groupIds) in desired {
            let id = Self.alarmID(forTime: key)
            let label = label(for: groupIds, repository: repository)
            // A "#once" key is a single alarm; everything else repeats.
            let once = key.hasSuffix("#once")
            let time = once ? String(key.dropLast("#once".count)) : key
            let days = once ? [] : Self.unionDays(forTime: time, in: repository.groups)
            let fireDate = RTAlarmTime.nextDate(for: time)

            // Always refresh these: the alarm may predate this launch, and the
            // set of groups behind it changes as groups are joined or left.
            recorder.registerScheduled(id: id, scheduledTime: fireDate)
            // Persist what a stop/snooze needs to become a status write — from
            // the in-process recorder or from a cold background launch via the
            // alarm's AppIntents alike. A repeating alarm also stores its
            // recurrence so a later firing derives against the right occurrence
            // rather than this (soon-stale) fireDate, and every record is stamped
            // with the owning account so a later sign-in can't inherit it.
            let slotHabits = habits.filter { groupIds.contains($0.key) }
            AlarmActionStore.shared.save(
                alarmID: id, groupIds: groupIds, scheduledTime: fireDate,
                time: once ? nil : time, days: once ? nil : days,
                uid: repository.signedInUid,
                habits: slotHabits.isEmpty ? nil : slotHabits,
                groupNames: Dictionary(uniqueKeysWithValues: groupIds.map { ($0, repository.group(id: $0)?.name ?? "") })
            )
            // With a habit, Stop opens the app (openAppWhenRun). iOS refuses to
            // start a Live Activity from Stop's background run — tested: it came
            // up as the fallback notification — but allows it once the app is in
            // the foreground, so that's where the lock-screen card is started.
            let opensApp = !slotHabits.isEmpty
            _ = liveActivitiesOn

            // Already on the system with the same label and days — leave it
            // alone rather than churning a live alarm.
            if live[key] != nil, scheduledLabels[key] == label, scheduledDays[key] ?? [] == days,
               scheduledOpensApp[key] ?? false == opensApp {
                continue
            }

            do {
                // Scheduling with the same id replaces the existing alarm.
                if once {
                    // A single alarm: one fixed fire at the next occurrence.
                    try await scheduler.scheduleAlarm(id: id, date: fireDate, label: label, stopOpensApp: opensApp)
                } else {
                    // Repeating: AlarmKit weekly recurrence on the selected days.
                    try await scheduler.scheduleAlarm(id: id, time: time, days: days, label: label, stopOpensApp: opensApp)
                }
                scheduledLabels[key] = label
                scheduledDays[key] = days
                scheduledOpensApp[key] = opensApp
            } catch {
                // Leave it; a later reconcile retries. The registrations above
                // are harmless if no alarm ends up existing.
            }
        }

        // Re-align the "Did you wake up?" safety-net reminders with the alarms
        // (and records) just reconciled.
        await AlarmCheckInNotifier.refresh()
    }

    /// Cancels an alarm and forgets it everywhere. The recorder must be told
    /// first: it infers a dismiss from an alerting alarm disappearing, so a
    /// programmatic cancel would otherwise be recorded as the user waking up.
    private func cancel(_ id: UUID, repository: GroupRepository) {
        recorder.unregister(id: id)
        AlarmActionStore.shared.remove(alarmID: id)
        try? scheduler.cancelAlarm(id: id)
        Task { await AlarmCheckInNotifier.remove(alarmID: id) }
    }

    /// Cancels every WhoZup alarm on the device and forgets every persisted
    /// alarm record. Called on sign-out and account deletion: the signed-out
    /// shell never mounts `RTRootView`, so no reconcile would otherwise run, and
    /// the previous account's alarms would keep ringing — and, with someone else
    /// signed in, could write into that account's groups.
    ///
    /// Only alarms whose id matches the one derived from their own slot are
    /// touched, exactly as in `reconcile`. Records are cleared first, so even if
    /// the recorder reads a cancel as a dismiss, the handler finds nothing to
    /// write.
    static func removeAllAlarms() {
        let scheduler = AlarmScheduler()
        AlarmActionStore.shared.removeAll()
        AlarmResponseJournal.removeAll()
        Task {
            await AlarmCheckInNotifier.removeAll()
            await RoutineCoordinator.shared.reset()
        }
        for slot in (try? scheduler.existingSlots()) ?? [] where alarmID(forTime: slot.key) == slot.id {
            try? scheduler.cancelAlarm(id: slot.id)
        }
    }

    /// The alarm's display label. A single group uses its name; a shared slot
    /// names one group and counts the rest, since the alarm belongs to all of
    /// them rather than to any one.
    private func label(for groupIds: [String], repository: GroupRepository) -> String {
        let names = groupIds.compactMap { repository.group(id: $0)?.name }.sorted()
        guard let first = names.first else { return "Alarm" }
        return names.count == 1 ? first : "\(first) +\(names.count - 1)"
    }

    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let ok = (try? await scheduler.ensureAuthorized()) ?? false
        authorized = ok
        return ok
    }
}
