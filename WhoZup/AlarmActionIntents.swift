//
//  AlarmActionIntents.swift
//  WhoZup
//
//  Makes alarm responses reach Firestore even when the app is backgrounded or
//  fully terminated — the normal case for an alarm.
//
//  AlarmKit presents the ringing UI and handles its Stop/Snooze buttons in the
//  *system* process; it does not bring the app to the foreground. So the
//  in-process `AlarmStatusRecorder`, which only sees `AlarmManager.alarmUpdates`
//  while the app runs, never observes an off-foreground response and the status
//  write is missed.
//
//  The fix: attach these `LiveActivityIntent`s to the alarm (see
//  `AlarmScheduler.makeConfiguration`). AlarmKit runs a button's intent by
//  launching the app *in the background even when it is closed*, so `perform()`
//  is the seam where we durably write the derived status to Firestore.
//

import AlarmKit
import AppIntents
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import os.log
import UIKit

// MARK: - Persisted alarm → groups map

/// What a background intent launch needs to turn an alarm response into a
/// Firestore write, persisted because the process that rings may be a cold one
/// with none of the app's in-memory bookkeeping (`alarmGroupMap`,
/// `scheduledTimes`) populated.
struct AlarmRecord: Codable {
    let groupIds: [String]
    let scheduledTime: Date
    /// Recurrence of a repeating alarm ("HH:mm" + weekdays, 1=Sun…7=Sat, empty
    /// = every day), so a background response can be derived against the
    /// occurrence it is actually answering rather than `scheduledTime`, which is
    /// captured once at reconcile and goes stale as a weekly alarm fires on
    /// later days. Absent for a one-time alarm — its `scheduledTime` is exact.
    var time: String?
    var days: [Int]?
    /// The account that owned the alarm when it was scheduled. A response is
    /// only ever written for this uid: if someone else has since signed in on
    /// the device, a stale alarm must not write *their* status into the
    /// previous account's groups.
    var uid: String?
    /// The owner's habits in the groups behind this alarm, by group id, and
    /// those groups' names — what an on-time Stop needs to open the routine
    /// from a cold background launch.
    var habits: [String: MemberHabit]?
    var groupNames: [String: String]?
}

/// UserDefaults-backed store mapping an AlarmKit alarm id to the groups it
/// covers and the time it was scheduled for. Written by `RTAlarmSync` when it
/// schedules/reconciles alarms; read by `AlarmActionHandler` at response time.
///
/// UserDefaults.standard is sufficient — the intents run in the main app
/// process, so no App Group container is needed.
struct AlarmActionStore {
    static let shared = AlarmActionStore()

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ id: UUID) -> String { "alarm.record.\(id.uuidString)" }

    func save(
        alarmID: UUID,
        groupIds: [String],
        scheduledTime: Date,
        time: String? = nil,
        days: [Int]? = nil,
        uid: String? = nil,
        habits: [String: MemberHabit]? = nil,
        groupNames: [String: String]? = nil
    ) {
        let record = AlarmRecord(groupIds: groupIds, scheduledTime: scheduledTime, time: time, days: days,
                                 uid: uid, habits: habits, groupNames: groupNames)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key(alarmID))
    }

    func record(for alarmID: UUID) -> AlarmRecord? {
        guard let data = defaults.data(forKey: key(alarmID)) else { return nil }
        return try? JSONDecoder().decode(AlarmRecord.self, from: data)
    }

    func remove(alarmID: UUID) {
        defaults.removeObject(forKey: key(alarmID))
    }

    /// Every persisted alarm record, by alarm id. The check-in safety net
    /// (`AlarmCheckInNotifier`) schedules from these alone, so it works from a
    /// background task without the repository loaded.
    func allRecords() -> [UUID: AlarmRecord] {
        var out: [UUID: AlarmRecord] = [:]
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("alarm.record.") {
            guard let id = UUID(uuidString: String(key.dropFirst("alarm.record.".count))),
                  let record = record(for: id) else { continue }
            out[id] = record
        }
        return out
    }

    /// Forgets every alarm record — on sign-out, so nothing the previous account
    /// scheduled can resolve to a write after someone else signs in.
    func removeAll() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("alarm.record.") || key.hasPrefix("alarm.handled.") {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Duplicate suppression

    /// The same tap can reach `AlarmActionHandler` twice — once via the alarm's
    /// AppIntent and once via `AlarmStatusRecorder` when the app is running — so
    /// the handler remembers the last action it wrote per alarm.
    private func handledKey(_ id: UUID) -> String { "alarm.handled.\(id.uuidString)" }

    func lastHandled(alarmID: UUID) -> (kind: String, at: Date)? {
        guard let dict = defaults.dictionary(forKey: handledKey(alarmID)),
              let kind = dict["kind"] as? String,
              let at = dict["at"] as? Date
        else { return nil }
        return (kind, at)
    }

    func markHandled(alarmID: UUID, kind: String, at: Date) {
        defaults.set(["kind": kind, "at": at], forKey: handledKey(alarmID))
    }
}

// MARK: - Firebase bootstrap

/// A single, idempotent Firebase configure path, safe to call from a background
/// intent launch where `WhoZupApp.init` may not have run yet.
enum FirebaseBootstrap {
    /// Keychain access group shared with the notification content extension so
    /// it can act as the signed-in user. Must match `keychain-access-groups` in
    /// both targets' entitlements. `<Team ID>.Akshay.WhoZup.shared`.
    static let sharedAuthAccessGroup = "7H4B5RGM9Y.Akshay.WhoZup.shared"

    static func ensureConfigured() {
        guard FirebaseApp.app() == nil else { return }
        FirebaseApp.configure()
        RTAnalytics.configure()
        // Store the auth session in the shared Keychain group so the notification
        // content extension can post an event RSVP as this user. No-op (via try?)
        // until the Keychain Sharing capability is added to the target.
        try? Auth.auth().useUserAccessGroup(sharedAuthAccessGroup)
        // Persistent on-disk cache (the default) is what makes an offline alarm
        // response durable: setData queues the mutation to disk and Firestore
        // replays it once connectivity returns. Set it explicitly, before the
        // first Firestore use, so the guarantee doesn't rely on the SDK default.
        let firestore = Firestore.firestore()
        let settings = firestore.settings
        settings.cacheSettings = PersistentCacheSettings()
        #if DEBUG
        // Local testing against the Firebase emulators, never prod (debug only).
        if let host = emulatorHost {
            Auth.auth().useEmulator(withHost: host, port: 9099)
            settings.host = "\(host):8080"
            settings.isSSLEnabled = false
            settings.cacheSettings = MemoryCacheSettings()
        }
        #endif
        firestore.settings = settings
    }

    #if DEBUG
    /// Set by launching with `WHOZUP_EMULATOR_HOST=127.0.0.1` (remembered, so
    /// intents and background tasks use it too); `WHOZUP_EMULATOR_HOST=off` clears it.
    private static var emulatorHost: String? {
        let key = "debug.emulatorHost"
        if let env = ProcessInfo.processInfo.environment["WHOZUP_EMULATOR_HOST"] {
            UserDefaults.standard.set(env == "off" ? nil : env, forKey: key)
        }
        return UserDefaults.standard.string(forKey: key)
    }
    #endif
}

// MARK: - Action handler

/// Turns a stop/snooze on a WhoZup alarm into a durable Firestore status write,
/// independent of the live `GroupRepository` and its listeners (which don't
/// exist in a cold background launch). Mirrors Android's
/// `GroupRepository.recordAlarmStatus`: resolve the uid from Auth, write directly.
///
/// Main-actor isolated so the intent path and the in-process recorder path are
/// serialized: the duplicate check below runs before the first suspension, so
/// two near-simultaneous calls for one tap can't both pass it.
/// What became of one attempt to turn an alarm response into a write.
enum AlarmHandleOutcome: Equatable {
    /// Queued to Firestore (durable on disk from here on).
    case written
    /// Deliberately not written, and never will be: a duplicate report of the
    /// same tap, an alarm that isn't (or is no longer) ours, or a different
    /// account signed in. Retrying can't change that.
    case ignored
    /// Couldn't be decided *yet* — typically the phone rebooted and hasn't been
    /// unlocked, so neither the alarm record (UserDefaults) nor the signed-in
    /// user (Keychain) is readable. The journal keeps it for a later retry.
    case retryLater
}

@MainActor
enum AlarmActionHandler {
    private static let logger = Logger(subsystem: "com.whozup.WhoZup", category: "AlarmActionHandler")
    private static let lateWindow: TimeInterval = 15 * 60
    /// Two reports of the same action on the same alarm within this window are
    /// one tap seen twice (intent + recorder), not two responses.
    private static let duplicateWindow: TimeInterval = 90

    /// The single entry point for every observed alarm response — the alarm's
    /// own Stop/Snooze intents and the in-process `AlarmStatusRecorder` alike.
    ///
    /// Order matters for reliability:
    /// 1. **Journal first.** The tap and its real time are written to a file
    ///    readable even before first unlock, before anything that can fail
    ///    (auth, records, network). Whatever happens next, the response is not
    ///    lost; `AlarmReliability.sweep()` replays it later.
    /// 2. **Settle the check-in safety net.** A captured stop means the "did you
    ///    wake up?" reminder for this ring must not appear; a snooze pushes it
    ///    past the snooze.
    /// 3. **Write**, and drop the journal entry unless the write must be retried.
    static func capture(alarmID: UUID, kind: MemberAction.Kind, at: Date = Date()) async {
        let entry = AlarmResponseJournal.append(alarmID: alarmID, kind: kind, at: at)
        switch kind {
        case .dismiss:
            await AlarmCheckInNotifier.resolve(alarmID: alarmID, respondedAt: at)
        case .snooze:
            await AlarmCheckInNotifier.deferPastSnooze(alarmID: alarmID, snoozedAt: at)
        }
        let outcome = await handle(alarmIDString: alarmID.uuidString, kind: kind, at: at)
        if outcome != .retryLater, let entry {
            AlarmResponseJournal.remove(entryID: entry.id)
        }
    }

    /// Replays every journalled response that hasn't been written yet. Safe to
    /// call any time; duplicate suppression makes a replay of something already
    /// written a no-op.
    static func drainJournal() async {
        for entry in AlarmResponseJournal.all() {
            let outcome = await handle(alarmIDString: entry.alarmID.uuidString, kind: entry.kind, at: entry.at)
            if outcome != .retryLater {
                AlarmResponseJournal.remove(entryID: entry.id)
            }
        }
    }

    /// Writes one response, judged at `at` — when the person actually tapped,
    /// which for a replayed journal entry may be well before now.
    @discardableResult
    static func handle(alarmIDString: String, kind: MemberAction.Kind, at now: Date = Date()) async -> AlarmHandleOutcome {
        guard let alarmID = UUID(uuidString: alarmIDString) else { return .ignored }

        FirebaseBootstrap.ensureConfigured()
        // Before the first unlock after a reboot, UserDefaults and the Keychain
        // read as empty; a missing record or user then means "not yet", not "no".
        let locked = !UIApplication.shared.isProtectedDataAvailable

        guard let record = AlarmActionStore.shared.record(for: alarmID) else {
            logger.error("No persisted record for alarm \(alarmIDString, privacy: .public)")
            RoutineLog.add("\(kind == .dismiss ? "Stop" : "Snooze"): no alarm record (locked=\(locked))")
            // Keep a recent tap and retry once the app has re-saved its alarm
            // records (see RTRootView: drain → reconcile → drain), rather than
            // dropping a real response. Give up after a few hours.
            let recent = Date().timeIntervalSince(now) < 3 * 3600
            return locked || recent ? .retryLater : .ignored
        }
        // FirebaseAuth restores the signed-in user synchronously from disk, so
        // this works before any listener/observer has started.
        guard let uid = Auth.auth().currentUser?.uid else {
            logger.error("No signed-in user; cannot record alarm status")
            RoutineLog.add("Stop: no signed-in user (locked=\(locked))")
            return locked ? .retryLater : .ignored
        }
        // Only ever write for the account that scheduled this alarm. Records
        // from before this field existed carry no uid and are trusted.
        if let owner = record.uid, owner != uid {
            logger.error("Alarm belongs to a different account; ignoring response")
            return .ignored
        }

        // Derive against the occurrence this response is actually answering. For
        // a repeating alarm the stored `scheduledTime` is stale after the first
        // firing (AlarmKit re-fires weekly with no reschedule), so recompute the
        // most recent fire from the recurrence; fall back to the stored time for
        // a one-time alarm or if the recurrence somehow yields nothing.
        let scheduledTime: Date = {
            guard let time = record.time else { return record.scheduledTime }
            return MissedAlarm.mostRecentFire(time: time, days: record.days ?? [], now: now)
                ?? record.scheduledTime
        }()

        let kindKey = kind == .dismiss ? "dismiss" : "snooze"
        let last = AlarmActionStore.shared.lastHandled(alarmID: alarmID)
        if let last, last.kind == kindKey, abs(now.timeIntervalSince(last.at)) < duplicateWindow {
            return .ignored
        }
        // A snooze already answered this ring: the routine only opens on a
        // first-ring Stop, because the habit is built at the alarm or not at all.
        let snoozedThisRing = last.map { $0.kind == "snooze" && $0.at >= scheduledTime.addingTimeInterval(-60) } ?? false
        AlarmActionStore.shared.markHandled(alarmID: alarmID, kind: kindKey, at: now)
        // The snooze is part of this ring's answer: a Stop after it is "snoozed",
        // not "woke up" (2026-11-06, E11) — so the day and the habit aren't green.
        var actions = [MemberAction(kind: kind, timestamp: now)]
        if snoozedThisRing, let last { actions.insert(MemberAction(kind: .snooze, timestamp: max(last.at, scheduledTime)), at: 0) }
        let derived = StatusDerivation.status(
            scheduledTime: scheduledTime,
            actions: actions,
            now: now,
            lateWindow: lateWindow
        )
        let status = GroupRepository.rtStatus(from: derived)
        let upAfterSnooze = kind == .dismiss && snoozedThisRing && status == .snoozed
        let detail = upAfterSnooze ? GroupRepository.upAfterSnoozeDetail(at: now) : GroupRepository.detail(for: status, at: now)

        let db = Firestore.firestore()
        for groupId in record.groupIds {
            enqueueWrite(db: db, groupId: groupId, uid: uid, status: status, detail: detail, at: now)
        }

        // A dismiss ends a *one-time* alarm's lifecycle, so drop its record. A
        // repeating alarm keeps its record: AlarmKit re-fires it on the next
        // scheduled day without the app running, and that response needs the
        // record too — dropping it here is what used to lose every response
        // after the first until the app happened to reconcile again. (A
        // cancelled alarm's record is removed by `RTAlarmSync.cancel`.)
        if kind == .dismiss, record.time == nil {
            AlarmActionStore.shared.remove(alarmID: alarmID)
        }

        // Stopped on time, first ring: open today's habit routine — straight
        // away, before anything touches the network. The tap is the response;
        // syncing it is the app's job, never the user's wait. A one-time alarm's
        // checklist opens after any Stop, snoozed or late included: there's no
        // habit to protect, only things to get done.
        if kind == .dismiss,
           let groupId = record.groupIds.first(where: { record.habits?[$0] != nil }),
           let habit = record.habits?[groupId],
           habit.checklist || (status == .wokeUp && !snoozedThisRing) {
            RoutineLog.add("Stop → open \(habit.kindNoun) for \(groupId)")
            await RoutineCoordinator.shared.begin(
                groupId: groupId,
                groupName: record.groupNames?[groupId] ?? "Alarms",
                habit: habit, uid: uid, alarmFiredAt: scheduledTime, now: now
            )
        } else if kind == .dismiss {
            RoutineLog.add("Stop without routine: status=\(status.storageKey) snoozedThisRing=\(snoozedThisRing) habits=\(record.habits?.count ?? 0)")
        }

        // The setData calls above already put the writes in Firestore's on-disk
        // queue, so the response is durable now, offline or not. Sync in the
        // background: ask iOS to send it once online, and nudge it along while
        // this launch is alive — without making anything wait for the server.
        PendingWritesSyncTask.schedule()
        Task { await confirmPendingWrites(db: db, timeout: .seconds(5)) }
        return .written
    }

    /// Records the answer to a "did you wake up?" check-in notification — the
    /// fallback for a ring whose Stop/Snooze never reached the app. Written as a
    /// *manual* response (like the in-app check-in card), against the day the
    /// alarm rang, to every group the alarm covered.
    static func recordCheckIn(
        alarmID: UUID,
        occurrence: Date,
        groupIds: [String],
        ownerUid: String?,
        status: RTStatus
    ) async {
        guard status == .wokeUp || status == .snoozed, !groupIds.isEmpty else { return }
        FirebaseBootstrap.ensureConfigured()
        guard let user = Auth.auth().currentUser else {
            logger.error("Check-in answered while signed out; dropping")
            return
        }
        if let ownerUid, ownerUid != user.uid { return }

        let now = Date()
        let detail = status == .wokeUp ? "woke up · confirmed from reminder" : "snoozed · confirmed from reminder"
        let verb = status == .wokeUp ? "woke up" : "snoozed"
        let name = user.displayName ?? user.email?.split(separator: "@").first.map(String.init) ?? "Someone"
        let day = GroupRepository.dayKey(occurrence)
        let db = Firestore.firestore()
        // Completion-handler forms on purpose: in an async context the bare call
        // resolves to the awaiting overload, which would hang offline. Queued
        // writes are durable on disk either way.
        for groupId in groupIds {
            let group = db.collection("groups").document(groupId)
            group.collection("statuses").document(user.uid).setData([
                "status": status.storageKey,
                "detail": detail,
                "manual": true,
                "respondedAt": Timestamp(date: now),
                "updatedAt": FieldValue.serverTimestamp(),
            ]) { _ in }
            group.collection("members").document(user.uid).collection("history").document(day).setData([
                "status": status.storageKey,
                "detail": detail,
                "date": day,
                "manual": true,
                "respondedAt": Timestamp(date: now),
                "updatedAt": FieldValue.serverTimestamp(),
            ]) { _ in }
            group.collection("activity").addDocument(data: [
                "kind": "response",
                "message": "\(name) marked that they \(verb)",
                "actorUid": user.uid,
                "createdAt": FieldValue.serverTimestamp(),
            ]) { _ in }
        }
        AlarmActionStore.shared.markHandled(alarmID: alarmID, kind: "checkin", at: now)
        // Durable in the on-disk queue already; sync without waiting on it.
        PendingWritesSyncTask.schedule()
        Task { await confirmPendingWrites(db: db, timeout: .seconds(5)) }
    }

    /// Queues the status doc plus (for real wake-up outcomes) the per-day
    /// history doc — the same two Firestore paths `GroupRepository.setMyStatus`
    /// and `recordHistory` use, so foreground and background writes are identical.
    ///
    /// Deliberately does not await a server ack: `setData` persists to the local
    /// mutation queue synchronously, which is what makes an offline response
    /// survive. Awaiting the ack here would hang until connectivity returned.
    ///
    /// Both docs are replaced rather than merged so a real response always
    /// clears an earlier automatic "no response" mark (its `auto` flag).
    private static func enqueueWrite(
        db: Firestore,
        groupId: String,
        uid: String,
        status: RTStatus,
        detail: String,
        at respondedAt: Date
    ) {
        db.collection("groups").document(groupId)
            .collection("statuses").document(uid)
            .setData([
                "status": status.storageKey,
                "detail": detail,
                "respondedAt": Timestamp(date: respondedAt),
                "updatedAt": FieldValue.serverTimestamp(),
            ])

        guard GroupRepository.historyStatuses.contains(status) else { return }
        let day = GroupRepository.dayKey(respondedAt)
        db.collection("groups").document(groupId)
            .collection("members").document(uid)
            .collection("history").document(day)
            .setData([
                "status": status.storageKey,
                "detail": detail,
                "date": day,
                "respondedAt": Timestamp(date: respondedAt),
                "updatedAt": FieldValue.serverTimestamp(),
            ])
    }

    /// Waits up to `timeout` for the queued writes to reach the server, then
    /// returns regardless. Firestore's local persistence has already made them
    /// durable, so this is a bounded best-effort confirmation, not a
    /// requirement: an offline device simply times out here and syncs the queued
    /// mutations on its next launch with connectivity.
    /// Returns whether everything synced within the timeout.
    @discardableResult
    static func confirmPendingWrites(db: Firestore, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await db.waitForPendingWrites()) != nil }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Intents attached to the alarm's Stop / Snooze buttons

/// Run when the user taps **Stop** on a WhoZup alarm. Records the dismiss, then
/// stops the alarm explicitly so the outcome is the same whether or not AlarmKit
/// also performs its default stop.
struct StopAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Alarm"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}
    init(alarmID: UUID) { self.alarmID = alarmID.uuidString }

    func perform() async throws -> some IntentResult {
        let tappedAt = Date()
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        await RoutineLog.add("Stop intent ran (background)")
        try? AlarmManager.shared.stop(id: id)
        await AlarmActionHandler.capture(alarmID: id, kind: .dismiss, at: tappedAt)
        return .result()
    }
}

/// The Stop used instead of `StopAlarmIntent` when the alarm has a habit routine
/// but Live Activities are off for WhoZup: `openAppWhenRun` brings the app
/// forward (after Face ID on a locked phone) so the routine screen can open —
/// the same flag Apple's WWDC25 AlarmKit sample uses for its "open app" button.
struct StopAlarmOpenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Alarm and Open Routine"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}
    init(alarmID: UUID) { self.alarmID = alarmID.uuidString }

    func perform() async throws -> some IntentResult {
        let tappedAt = Date()
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        await RoutineLog.add("Stop intent ran (opens app)")
        try? AlarmManager.shared.stop(id: id)
        await AlarmActionHandler.capture(alarmID: id, kind: .dismiss, at: tappedAt)
        return .result()
    }
}

/// Run when the user taps **Snooze**. Records the snooze, then starts the native
/// countdown so the alarm re-alerts even if supplying this intent replaced the
/// button's default `.countdown` behavior.
struct SnoozeAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Snooze Alarm"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {}
    init(alarmID: UUID) { self.alarmID = alarmID.uuidString }

    func perform() async throws -> some IntentResult {
        let tappedAt = Date()
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        try? AlarmManager.shared.countdown(id: id)
        await AlarmActionHandler.capture(alarmID: id, kind: .snooze, at: tappedAt)
        return .result()
    }
}
