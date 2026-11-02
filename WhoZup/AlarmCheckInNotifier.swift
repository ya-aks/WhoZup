//
//  AlarmCheckInNotifier.swift
//  WhoZup
//
//  The reliability layer around alarm responses on iOS.
//
//  What AlarmKit actually reports (iOS 26.4 SDK + Apple docs):
//    - `Alarm.State` has exactly four cases — scheduled, countdown, paused,
//      alerting. There is no "dismissed"/"stopped"/"timed out" state and no
//      reason code; a stopped one-shot alarm simply disappears from
//      `alarmUpdates`, and a stopped *repeating* alarm goes back to `.scheduled`
//      (`AlarmManager.stop(id:)` docs).
//    - `stopIntent` runs when a person taps Stop; `secondaryIntent` when they
//      tap the secondary (Snooze) button. Those are the only two app callbacks.
//    - Developer reports (forums 815064, 852856) say dismissing the alerting
//      Live Activity banner while the phone is unlocked — swiping it away, or
//      the side button — stops the alarm *without* running `stopIntent`.
//      Apple's DTS hasn't confirmed or ruled it out, so we must assume it.
//    - The system never times an alarm out by itself (DTS: it "expects
//      explicit user interaction"), and `alarmUpdates` is only observed while
//      the app process is alive.
//
//  So a response can go unseen. This file closes that gap three ways:
//    1. `AlarmResponseJournal` — every observed tap is written to an
//       unprotected file *first*, so a write that can't happen yet (phone not
//       unlocked since reboot, so no Keychain / UserDefaults) is replayed later.
//    2. `AlarmCheckInNotifier` — for every upcoming ring we pre-schedule a local
//       "Did you wake up?" notification a few minutes after it. Capturing a Stop
//       cancels it; a Snooze pushes it out. If nothing was captured, it appears,
//       and its "I'm up" / "I snoozed" buttons record the answer directly.
//    3. `AlarmReliability.sweep()` — replays the journal and tops up the
//       check-in schedule on launch, foreground, unlock and background tasks.
//

import Foundation
import os.log
import UIKit
import UserNotifications

// MARK: - Response journal

/// One response the app saw, kept until it has been written.
struct JournalEntry: Codable, Equatable {
    let id: UUID
    let alarmID: UUID
    let kindKey: String
    let at: Date

    var kind: MemberAction.Kind { kindKey == "snooze" ? .snooze : .dismiss }
}

/// An append-only list of alarm responses, stored as a small JSON file with
/// **no file protection** so it is writable while the phone is still locked
/// after a reboot — exactly when the alarm, the intent and the user's tap can
/// happen but UserDefaults and the Keychain cannot be read. It holds only alarm
/// ids, an action and a time: nothing personal.
enum AlarmResponseJournal {
    private static let lock = NSLock()

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alarm-response-journal.json")
    }

    private static func read() -> [JournalEntry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([JournalEntry].self, from: data)) ?? []
    }

    private static func write(_ entries: [JournalEntry]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .noFileProtection])
    }

    /// Appends a response. Entries older than a week are dropped on the way —
    /// past that the missed-alarm reconcile owns the day anyway.
    @discardableResult
    static func append(alarmID: UUID, kind: MemberAction.Kind, at: Date) -> JournalEntry? {
        lock.lock(); defer { lock.unlock() }
        let entry = JournalEntry(id: UUID(), alarmID: alarmID, kindKey: kind == .snooze ? "snooze" : "dismiss", at: at)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        write(read().filter { $0.at > cutoff } + [entry])
        return entry
    }

    static func remove(entryID: UUID) {
        lock.lock(); defer { lock.unlock() }
        write(read().filter { $0.id != entryID })
    }

    static func all() -> [JournalEntry] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        write([])
    }
}

// MARK: - Check-in safety net

/// Schedules, cancels and answers the "Did you wake up?" notifications.
@MainActor
enum AlarmCheckInNotifier {
    static let categoryID = "ALARM_CHECKIN_CATEGORY"
    static let wokeUpAction = "CHECKIN_WOKE_UP"
    static let snoozedAction = "CHECKIN_SNOOZED"

    /// How long after the alarm rings the reminder appears if no response was
    /// captured. Short enough to still be useful to the group, long enough not
    /// to talk over a ringing alarm someone is about to stop.
    static let grace: TimeInterval = 10 * 60
    /// After a captured snooze: the snooze itself plus this much.
    static let afterSnooze: TimeInterval = AlarmScheduler.defaultSnoozeInterval + 5 * 60
    /// How far ahead reminders are pre-scheduled. Topped up by every sweep.
    static let horizonDays = 7
    /// iOS keeps at most 64 pending local notifications per app.
    static let maxPending = 40

    private static let prefix = "alarm.checkin."
    private static let resolvedKey = "alarm.checkin.resolved"
    private static let logger = Logger(subsystem: "com.whozup.WhoZup", category: "AlarmCheckIn")
    private static var center: UNUserNotificationCenter { .current() }

    /// The category with the two answers. `.authenticationRequired` makes sure
    /// the phone is unlocked when the answer runs, so the signed-in user (in the
    /// Keychain) is readable and the write can't be refused for that reason.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryID,
            actions: [
                UNNotificationAction(identifier: wokeUpAction, title: "I'm up", options: [.authenticationRequired]),
                UNNotificationAction(identifier: snoozedAction, title: "I snoozed it", options: [.authenticationRequired]),
            ],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    // MARK: Identity

    /// One reminder per ring: the alarm id plus the exact fire instant. Being
    /// derived, scheduling the same ring twice replaces rather than duplicates.
    static func identifier(alarmID: UUID, fire: Date) -> String {
        "\(prefix)\(alarmID.uuidString).\(Int(fire.timeIntervalSince1970))"
    }

    static func parse(_ identifier: String) -> (alarmID: UUID, fire: Date)? {
        guard identifier.hasPrefix(prefix), !identifier.hasPrefix(resolvedKey) else { return nil }
        let parts = identifier.dropFirst(prefix.count).split(separator: ".")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let epoch = TimeInterval(String(parts[1])) else { return nil }
        return (id, Date(timeIntervalSince1970: epoch))
    }

    /// The rings of `record` that fall between `from` and `to`. Pure, so the
    /// scheduling rule can be unit-tested.
    static func fires(of record: AlarmRecord, from: Date, to: Date, calendar: Calendar = .current) -> [Date] {
        guard let time = record.time else {
            return (from...to).contains(record.scheduledTime) ? [record.scheduledTime] : []
        }
        let parts = time.split(separator: ":")
        guard let hour = parts.first.flatMap({ Int($0) }) else { return [] }
        let minute = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let days = Set(record.days ?? [])
        var out: [Date] = []
        var day = calendar.startOfDay(for: from)
        while day <= to {
            if days.isEmpty || days.contains(calendar.component(.weekday, from: day)),
               let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
               fire >= from, fire <= to {
                out.append(fire)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    // MARK: Scheduling

    /// Makes the pending reminders match the alarms on this device: adds one
    /// for each upcoming ring, removes ones whose alarm or day went away, and
    /// leaves a reminder for a ring that has already happened untouched (it is
    /// still waiting to see whether a response arrives).
    static func refresh(now: Date = Date()) async {
        let records = AlarmActionStore.shared.allRecords()
        let resolved = resolvedSet()
        let horizon = now.addingTimeInterval(TimeInterval(horizonDays) * 24 * 3600)

        // Every ring a reminder may legitimately exist for, past day included.
        var valid = Set<String>()
        var upcoming: [(id: String, alarmID: UUID, fire: Date, record: AlarmRecord)] = []
        for (alarmID, record) in records {
            for fire in fires(of: record, from: now.addingTimeInterval(-24 * 3600), to: horizon) {
                let id = identifier(alarmID: alarmID, fire: fire)
                valid.insert(id)
                // Only rings still in the future get a new reminder: a ring that
                // already passed before we knew about it (an alarm set for a time
                // earlier today) must not ask about a wake-up that never was.
                if fire > now, !resolved.contains(id) {
                    upcoming.append((id, alarmID, fire, record))
                }
            }
        }

        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { parse($0) != nil }
        let stale = pending.filter { !valid.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }

        let pendingSet = Set(pending)
        let room = max(0, maxPending - (pendingSet.count - stale.count))
        for item in upcoming.sorted(by: { $0.fire < $1.fire }).filter({ !pendingSet.contains($0.id) }).prefix(room) {
            await add(id: item.id, alarmID: item.alarmID, fire: item.fire, record: item.record,
                      trigger: calendarTrigger(item.fire.addingTimeInterval(grace)))
        }
    }

    /// A captured Stop: this ring needs no reminder. Removes the reminder for
    /// the most recent ring of the alarm at or before the tap — pending or
    /// already showing — and remembers it so a later refresh doesn't re-add it.
    static func resolve(alarmID: UUID, respondedAt: Date) async {
        let ids = await matching(alarmID: alarmID, around: respondedAt)
        guard !ids.isEmpty else {
            // Not scheduled (e.g. the sweep hadn't run yet): still remember the
            // ring this answers so a refresh can't add a reminder for it.
            if let record = AlarmActionStore.shared.record(for: alarmID),
               let fire = fires(of: record, from: respondedAt.addingTimeInterval(-24 * 3600), to: respondedAt).last {
                markResolved([identifier(alarmID: alarmID, fire: fire)])
            }
            return
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        markResolved(ids)
    }

    /// A captured Snooze: the person is responding but may not be up yet. Move
    /// the reminder to after the snooze, so if the second ring's Stop is the
    /// one that slips through, they are still asked.
    static func deferPastSnooze(alarmID: UUID, snoozedAt: Date) async {
        guard let record = AlarmActionStore.shared.record(for: alarmID) else { return }
        let fire = fires(of: record, from: snoozedAt.addingTimeInterval(-24 * 3600), to: snoozedAt).last
            ?? record.scheduledTime
        let id = identifier(alarmID: alarmID, fire: fire)
        guard !resolvedSet().contains(id) else { return }
        center.removeDeliveredNotifications(withIdentifiers: [id])
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: afterSnooze, repeats: false)
        await add(id: id, alarmID: alarmID, fire: fire, record: record, trigger: trigger)
    }

    /// Forgets every reminder for one alarm — when it is cancelled.
    static func remove(alarmID: UUID) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let ids = (pending + delivered).filter { parse($0)?.alarmID == alarmID }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Forgets every reminder — on sign-out.
    static func removeAll() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let ids = (pending + delivered).filter { parse($0) != nil }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        UserDefaults.standard.removeObject(forKey: resolvedKey)
    }

    // MARK: Answering

    /// Handles a tap on a check-in notification. Returns false if it wasn't one.
    static func handle(response: UNNotificationResponse) async -> Bool {
        let request = response.notification.request
        guard request.content.categoryIdentifier == categoryID,
              let (alarmID, fire) = parse(request.identifier) else { return false }
        let info = request.content.userInfo
        let groupIds = info["groupIds"] as? [String] ?? []

        switch response.actionIdentifier {
        case wokeUpAction, snoozedAction:
            markResolved([request.identifier])
            await AlarmActionHandler.recordCheckIn(
                alarmID: alarmID,
                occurrence: fire,
                groupIds: groupIds,
                ownerUid: info["ownerUid"] as? String,
                status: response.actionIdentifier == wokeUpAction ? .wokeUp : .snoozed
            )
        case UNNotificationDefaultActionIdentifier:
            // Open the group: its check-in card asks the same question in-app.
            if let first = groupIds.first { PendingGroupStore.shared.groupId = first }
        default:
            // Cleared without answering: leave it; the in-app card still asks.
            break
        }
        return true
    }

    // MARK: Private

    private static func add(id: String, alarmID: UUID, fire: Date, record: AlarmRecord, trigger: UNNotificationTrigger) async {
        let content = UNMutableNotificationContent()
        content.title = "Did you wake up?"
        content.body = "Your \(RTAlarmTime.display(RTAlarmTime.string(from: fire))) alarm's response didn't reach WhoZup. Let your group know."
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.interruptionLevel = .active
        var info: [String: Any] = ["groupIds": record.groupIds, "kind": "alarmCheckIn"]
        if let uid = record.uid { info["ownerUid"] = uid }
        content.userInfo = info
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            logger.error("Failed to schedule check-in: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func calendarTrigger(_ date: Date) -> UNCalendarNotificationTrigger {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
    }

    /// Reminder ids for `alarmID` whose ring is the most recent one at or before
    /// `at` (allowing a minute of clock slack), pending or delivered.
    private static func matching(alarmID: UUID, around at: Date) async -> [String] {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let candidates = Set(pending + delivered).compactMap { id -> (String, Date)? in
            guard let parsed = parse(id), parsed.alarmID == alarmID,
                  parsed.fire <= at.addingTimeInterval(60),
                  parsed.fire >= at.addingTimeInterval(-24 * 3600) else { return nil }
            return (id, parsed.fire)
        }
        guard let latest = candidates.map(\.1).max() else { return [] }
        return candidates.filter { $0.1 == latest }.map(\.0)
    }

    private static func resolvedSet() -> Set<String> {
        let dict = UserDefaults.standard.dictionary(forKey: resolvedKey) as? [String: Date] ?? [:]
        return Set(dict.keys)
    }

    private static func markResolved(_ ids: [String]) {
        var dict = UserDefaults.standard.dictionary(forKey: resolvedKey) as? [String: Date] ?? [:]
        let cutoff = Date().addingTimeInterval(-8 * 24 * 3600)
        dict = dict.filter { $0.value > cutoff }
        for id in ids { dict[id] = Date() }
        UserDefaults.standard.set(dict, forKey: resolvedKey)
    }
}

// MARK: - Sweep

@MainActor
enum AlarmReliability {
    /// Replays any response that couldn't be written when it happened, then
    /// re-aligns the check-in reminders with the alarms on the device. Called on
    /// launch, foreground, first unlock after reboot, and from background tasks.
    static func sweep() async {
        await AlarmActionHandler.drainJournal()
        await AlarmCheckInNotifier.refresh()
    }

    /// Records that the person answered today's check-in in the app, so the
    /// notification for that ring is withdrawn.
    static func checkInAnsweredInApp(slotKey: String, fire: Date) async {
        await AlarmCheckInNotifier.resolve(alarmID: RTAlarmSync.alarmID(forTime: slotKey), respondedAt: fire.addingTimeInterval(1))
    }
}
