//
//  RoutineCoordinator.swift
//  WhoZup
//
//  Runs today's habit routine after an on-time Stop.
//
//  Presentation: an alarm with a habit is scheduled with `StopAlarmOpenIntent`
//  (`openAppWhenRun`), so Stop brings the app forward. From the foreground:
//    1. A Live Activity on the lock screen / Dynamic Island. (Starting one from
//       Stop's background run is refused by iOS — tested on device — so it is
//       always started here, in the foreground.)
//    2. The routine screen in the app, alongside it — or alone when Live
//       Activities are switched off for WhoZup.
//    3. If neither happened (the activity was refused at runtime and the app
//       is in the background), a local "Start your routine" notification.
//
//  Progress is persisted locally first, then merged into the member's status
//  and history docs (`routine` field) — fire-and-forget, so offline ticks are
//  durable in Firestore's queue like every other alarm response.
//

import ActivityKit
import FirebaseAuth
import FirebaseFirestore
import Foundation
import os.log
import UIKit
import UserNotifications

/// A short, persisted trail of what the routine did on this phone — readable
/// from Profile → Routine log — so a card that doesn't appear says why.
/// Unprotected so a Stop on a locked phone still records.
enum RoutineLog {
    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("routine-log.txt")
    }

    static func add(_ line: String) {
        guard let url else { return }
        let stamp = Date().formatted(date: .abbreviated, time: .standard)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += "\(stamp)  \(line)\n"
        // Keep the last 200 lines.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(200)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: [.atomic, .noFileProtection])
    }

    static func read() -> String {
        guard let url else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The routine in progress, persisted so a cold background launch (a step
/// tapped on the lock screen) can continue it.
struct RoutineSession: Codable, Equatable {
    var groupId: String
    var groupName: String
    var uid: String
    var habit: MemberHabit
    var day: String
    var done: [Bool]
    var tiny: Bool
    /// Per step: done with its tiny version.
    var tinySteps: [Bool]?
    var startedAt: Date
    var deadline: Date
    var completedAt: Date?

    var isComplete: Bool { tiny || (!done.isEmpty && !done.contains(false)) }
    func isOpen(now: Date = Date()) -> Bool { !isComplete && now <= deadline }
    var nextIndex: Int? { done.firstIndex(of: false) }
    var doneCount: Int { done.filter { $0 }.count }

    var progress: RoutineProgress {
        RoutineProgress(
            day: day, done: done, tiny: tiny, tinySteps: tinySteps,
            startedAt: Timestamp(date: startedAt),
            deadline: Timestamp(date: deadline),
            completedAt: completedAt.map { Timestamp(date: $0) }
        )
    }

    var contentState: RoutineActivityAttributes.ContentState {
        .init(done: done, tiny: tiny, tinySteps: tinySteps)
    }
}

@MainActor
@Observable
final class RoutineCoordinator {
    static let shared = RoutineCoordinator()

    static let notificationID = "routine.start"
    /// "Finish your routine" — kept while a routine is open with no lock-screen card.
    static let pendingNotificationID = "routine.pending"

    private(set) var session: RoutineSession?
    /// Set when the routine screen should cover the app.
    var presentRoutine = false

    private let defaultsKey = "routine.session"
    private let logger = Logger(subsystem: "com.whozup.WhoZup", category: "Routine")

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            session = try? JSONDecoder().decode(RoutineSession.self, from: data)
        }
        expireIfNeeded()
    }

    /// Opens the routine screen only while there is something left to do. A
    /// tap on a finished or timed-out card (or its notification) just opens
    /// the app — there's nothing to check off, so no screen to dismiss.
    func presentIfOpen() {
        expireIfNeeded()
        if openSession != nil { presentRoutine = true }
    }

    /// Opens today's routine for `group` from anywhere in the app ("Continue",
    /// the "Routine pending" pill). Works even when this phone didn't start it —
    /// it began on your other device, or this phone's Stop never reached the
    /// routine — by taking over the synced progress, so an open routine is never
    /// out of reach while there's time left.
    func open(group: RTGroup, now: Date = Date()) {
        expireIfNeeded(now: now)
        if let s = openSession, s.groupId == group.id, s.day == GroupRepository.dayKey(now) {
            presentRoutine = true
            ensureLiveActivity()
            return
        }
        guard let me = group.roster.first(where: { $0.isYou }),
              let habit = group.alarmOnce ? me.checklist : me.habit,
              let progress = me.routine, adopt(groupId: group.id, groupName: group.name, uid: me.uid,
                                               habit: habit, progress: progress, now: now)
        else { return }
        presentRoutine = true
        ensureLiveActivity()
    }

    /// Makes a routine that's open in Firestore the local session. Returns
    /// whether there is now an open session for it.
    @discardableResult
    func adopt(groupId: String, groupName: String, uid: String, habit: MemberHabit,
               progress: RoutineProgress, now: Date = Date()) -> Bool {
        guard progress.isOpen(now: now), progress.done.count == habit.steps.count,
              let startedAt = progress.startedAt?.dateValue(), let deadline = progress.deadline?.dateValue()
        else { return false }
        // Already running here and at least as far along: keep the local copy.
        if let s = session, s.groupId == groupId, s.day == progress.day, s.doneCount >= progress.doneCount {
            return s.isOpen(now: now)
        }
        RoutineLog.add("Adopted the synced \(habit.kindNoun) for \(groupId) (\(progress.doneCount) of \(progress.total))")
        store(RoutineSession(
            groupId: groupId, groupName: groupName, uid: uid, habit: habit, day: progress.day,
            done: progress.done, tiny: progress.tiny,
            tinySteps: progress.tinySteps ?? Array(repeating: false, count: progress.done.count),
            startedAt: startedAt, deadline: deadline, completedAt: nil
        ))
        MissedAlarmBackgroundTask.schedule(soonest: deadline.addingTimeInterval(5))
        return true
    }

    /// The open routine, if it is still within its window.
    var openSession: RoutineSession? {
        guard let session, !session.isComplete, Date() <= session.deadline else { return nil }
        return session
    }

    // MARK: Starting

    /// Starts today's routine for `groupId` after an on-time, first-ring Stop.
    /// Idempotent per group and day: the intent and the in-app recorder can both
    /// report one Stop.
    func begin(groupId: String, groupName: String, habit: MemberHabit, uid: String, alarmFiredAt: Date, now: Date = Date()) async {
        let day = GroupRepository.dayKey(alarmFiredAt)
        if let session, session.groupId == groupId, session.day == day {
            RoutineLog.add("begin: already started today for \(groupId)")
            return
        }
        guard !habit.steps.isEmpty else { RoutineLog.add("begin: habit has no steps"); return }

        let new = RoutineSession(
            groupId: groupId, groupName: groupName, uid: uid, habit: habit, day: day,
            done: Array(repeating: false, count: habit.steps.count), tiny: false,
            tinySteps: Array(repeating: false, count: habit.steps.count),
            startedAt: now,
            deadline: now.addingTimeInterval(TimeInterval(habit.windowMinutes * 60)),
            completedAt: nil
        )
        await endLiveActivities()
        clearPendingNotification()
        store(new)
        write(new)
        // Ask for background time at the deadline to take the card down then.
        MissedAlarmBackgroundTask.schedule(soonest: new.deadline.addingTimeInterval(5))

        if startLiveActivity(new) {
            // Started from the foreground (Stop opened the app): show the routine
            // here too; the card stays on the lock screen for later.
            if UIApplication.shared.applicationState == .active { presentRoutine = true }
            return
        }
        RoutineLog.add("No Live Activity; app state=\(UIApplication.shared.applicationState == .active ? "active" : "background")")
        // No lock-screen card. In the foreground (openAppWhenRun brought us
        // here, or the app was already open) show the routine screen; in the
        // background, ask with a notification.
        if UIApplication.shared.applicationState == .active {
            presentRoutine = true
        } else {
            await postStartNotification(new)
        }
    }

    // MARK: Progress

    /// Marks a step done. Steps are sequential and one-way: only the next step
    /// can be completed (step 2 before step 1 makes no sense — each cues the
    /// next), and a done step can't be undone.
    /// `tiny`: done with the step's tiny version rather than the full step.
    func completeStep(_ index: Int, tiny: Bool = false, groupId: String? = nil) async {
        guard var s = session, groupId == nil || s.groupId == groupId else { return }
        guard s.isOpen() else {
            // A tap on a card whose time ran out: just take the card away.
            expireIfNeeded()
            return
        }
        guard index == s.nextIndex else { return }
        s.done[index] = true
        var tinySteps = s.tinySteps ?? Array(repeating: false, count: s.done.count)
        if tinySteps.indices.contains(index) { tinySteps[index] = tiny && !(s.habit.steps[index].tiny ?? "").isEmpty }
        s.tinySteps = tinySteps
        await commit(s)
    }

    private func commit(_ updated: RoutineSession) async {
        var s = updated
        let finishedNow = s.isComplete && s.completedAt == nil
        if finishedNow { s.completedAt = Date() }
        if !s.isComplete { s.completedAt = nil }
        store(s)
        write(s)
        if finishedNow { announceFinished(s) }
        await updateLiveActivity(s)
        if s.isComplete { clearPendingNotification() }
    }

    /// The routine screen was closed (or the app left) with steps still to do.
    /// Something must stay in front of the person: the lock-screen card if it's
    /// still up, otherwise a "Finish your routine" notification to tap.
    func routineLeftOpen() async {
        guard let s = openSession else { return }
        if hasRunningLiveActivity(for: s) { return }
        let content = UNMutableNotificationContent()
        content.title = s.habit.checklist
            ? "Finish your \(s.habit.name.lowercased()) · \(s.doneCount) of \(s.done.count)"
            : "Finish your \(s.habit.name) routine · \(s.doneCount) of \(s.done.count)"
        let next = s.nextIndex.map { s.habit.steps[$0].title } ?? ""
        content.body = "Next: \(next) · by \(RTAlarmTime.display(RTAlarmTime.string(from: s.deadline)))"
        content.sound = nil
        content.interruptionLevel = .active
        content.userInfo = ["kind": "routine"]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.pendingNotificationID, content: content, trigger: nil)
        )
    }

    /// The app is in the foreground (opened from "Start your routine", or any
    /// other way) with today's routine still open and no card showing: start
    /// the lock-screen Live Activity now. iOS refuses to start one from Stop's
    /// background run, but allows it from the foreground.
    func ensureLiveActivity() {
        guard let s = openSession, UIApplication.shared.applicationState == .active,
              !hasRunningLiveActivity(for: s) else { return }
        if startLiveActivity(s) {
            RoutineLog.add("Live Activity started from the foreground")
            clearPendingNotification()
        }
    }

    private func hasRunningLiveActivity(for s: RoutineSession) -> Bool {
        Activity<RoutineActivityAttributes>.activities.contains {
            $0.attributes.groupId == s.groupId && $0.activityState == .active
        }
    }

    private func clearPendingNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.pendingNotificationID, Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.pendingNotificationID])
    }

    /// Ends the routine once its window has passed; progress stays recorded.
    /// iOS gives an app no wake-up at the deadline, so this runs whenever the
    /// app next gets time (launch, foreground, a step tap, background refresh);
    /// until then the card itself shows "Time's up" (it goes stale at the deadline).
    func expireIfNeeded(now: Date = Date()) {
        guard let s = session, !s.isComplete, now > s.deadline else { return }
        clearPendingNotification()
        if presentRoutine { presentRoutine = false }
        guard !Activity<RoutineActivityAttributes>.activities.isEmpty else { return }
        RoutineLog.add("Window closed: ending the Live Activity")
        Task { await endLiveActivities() }
    }

    /// Clears everything — on sign-out.
    func reset() async {
        await endLiveActivities()
        clearPendingNotification()
        session = nil
        presentRoutine = false
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: Persistence and sync

    private func store(_ s: RoutineSession) {
        session = s
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    /// Merges progress into the live status and the day's history. Queued, not
    /// awaited: offline it lands in Firestore's on-disk queue.
    private func write(_ s: RoutineSession) {
        FirebaseBootstrap.ensureConfigured()
        guard Auth.auth().currentUser?.uid == s.uid else { return }
        let member = Firestore.firestore().collection("groups").document(s.groupId)
        let routine = s.progress.firestoreData
        member.collection("statuses").document(s.uid)
            .setData(["routine": routine], merge: true) { _ in }
        member.collection("members").document(s.uid).collection("history").document(s.day)
            .setData(["routine": routine, "date": s.day], merge: true) { _ in }
    }

    private func announceFinished(_ s: RoutineSession) {
        guard let user = Auth.auth().currentUser, user.uid == s.uid else { return }
        let name = user.displayName ?? "Someone"
        let what = s.habit.checklist
            ? "finished their \(s.habit.showSteps ? s.habit.name.lowercased() : "checklist")"
            : (s.habit.showSteps ? "finished their \(s.habit.name) routine" : "finished their routine")
        Firestore.firestore().collection("groups").document(s.groupId).collection("activity").addDocument(data: [
            "kind": "routine_done",
            "message": "\(name) \(what)\(s.tiny || (s.tinySteps ?? []).contains(true) ? " (with a tiny version)" : "")",
            "actorUid": s.uid,
            "createdAt": FieldValue.serverTimestamp(),
        ]) { _ in }
    }

    // MARK: Live Activity

    private func startLiveActivity(_ s: RoutineSession) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.log("Live Activities are off; using the app instead")
            RoutineLog.add("Live Activities are OFF for WhoZup")
            return false
        }
        let attributes = RoutineActivityAttributes(
            groupId: s.groupId, groupName: s.groupName, habitName: s.habit.name,
            steps: s.habit.steps.map(\.title), tinies: s.habit.steps.map { $0.tiny ?? "" },
            deadline: s.deadline
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: s.contentState, staleDate: s.deadline),
                pushType: nil
            )
            RoutineLog.add("Live Activity started (\(activity.id.prefix(8)))")
            return true
        } catch {
            logger.error("Routine Live Activity refused: \(error.localizedDescription, privacy: .public)")
            RoutineLog.add("Live Activity REFUSED: \(String(describing: error))")
            return false
        }
    }

    private func updateLiveActivity(_ s: RoutineSession) async {
        for activity in Activity<RoutineActivityAttributes>.activities where activity.attributes.groupId == s.groupId {
            let content = ActivityContent(state: s.contentState, staleDate: s.deadline)
            if s.isComplete {
                // Finished: take the card off the lock screen now. Leaving it up
                // only invited a tap into a checklist with nothing left to do.
                await activity.end(content, dismissalPolicy: .immediate)
            } else {
                await activity.update(content)
            }
        }
    }

    private func endLiveActivities() async {
        for activity in Activity<RoutineActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: Notification fallback

    private func postStartNotification(_ s: RoutineSession) async {
        let content = UNMutableNotificationContent()
        content.title = s.habit.checklist ? "Start your \(s.habit.name.lowercased())" : "Start your \(s.habit.name) routine"
        content.body = "Step 1: \(s.habit.steps.first?.title ?? "") · finish by \(RTAlarmTime.display(RTAlarmTime.string(from: s.deadline)))"
        content.sound = .default
        content.userInfo = ["kind": "routine"]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        )
    }
}

/// The ways a routine starts from inside the app, shared by the UI and the
/// end-to-end hooks (`E2EHooks`) so tests run exactly the code people tap.
/// Rules: docs/habits.md. Scenarios: docs/testing.md.
@MainActor
enum RoutineEntry {
    enum CheckInOutcome: String { case startedLive, askAfterFact, nothingToAsk }

    /// "I woke up" / "I snoozed" on the check-in card for an alarm whose
    /// response never reached the app. Records the answer; then, if there's a
    /// habit or checklist to follow up: inside its window, start the live
    /// routine as a Stop would; after it, ask after the fact.
    static func answerCheckIn(repository: GroupRepository, groupId: String, pending: RTPendingCheckIn,
                              status: RTStatus, now: Date = Date()) async -> (CheckInOutcome, MemberHabit?) {
        // Decide before recording: the roster changes once the status lands.
        let habit = repository.checkInFollowUp(groupId: groupId, status: status)
        await repository.recordManualCheckIn(groupId: groupId, status: status)
        guard let habit else { return (.nothingToAsk, nil) }
        if let uid = repository.signedInUid,
           now < pending.fireDate.addingTimeInterval(TimeInterval(habit.windowMinutes * 60)) {
            RoutineLog.add("Check-in → open \(habit.kindNoun) for \(groupId)")
            await RoutineCoordinator.shared.begin(
                groupId: groupId, groupName: repository.group(id: groupId)?.name ?? "Alarms",
                habit: habit, uid: uid, alarmFiredAt: pending.fireDate)
            return (.startedLive, habit)
        }
        return (.askAfterFact, habit)
    }

    /// When today's alarm rang (nil if it hasn't yet, or a one-time alarm on another day).
    nonisolated static func todaysFire(group: RTGroup, now: Date) -> Date? {
        if group.alarmOnce {
            guard let fire = group.alarmOnceFireDate, Calendar.current.isDate(fire, inSameDayAs: now) else { return nil }
            return fire <= now ? fire : nil
        }
        let parts = group.alarm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let fire = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now),
              fire <= now else { return nil }
        return fire
    }

    /// Until when a routine that never started can still be started from the
    /// Start button: you're marked up today (any answer, for a checklist, which
    /// follows any Stop) and today's alarm time + window hasn't passed.
    nonisolated static func startableUntil(group: RTGroup, habit: MemberHabit, now: Date) -> Date? {
        guard let me = group.roster.first(where: { $0.isYou }),
              habit.checklist ? [.wokeUp, .snoozed, .runningLate].contains(me.status) : me.status == .wokeUp,
              let fire = todaysFire(group: group, now: now) else { return nil }
        let until = fire.addingTimeInterval(TimeInterval(habit.windowMinutes * 60))
        return now < until ? until : nil
    }

    /// Today's occurrence when the habit didn't run because you weren't up on
    /// the first ring: shown on Today's routine as missed before the next
    /// occurrence (2026-11-06, E11). Nil for a checklist, which opens after any
    /// Stop. Same copy as Android `RoutineEntry.missedToday`.
    nonisolated static func missedToday(group: RTGroup, habit: MemberHabit) -> String? {
        guard !habit.checklist, let me = group.roster.first(where: { $0.isYou }) else { return nil }
        switch me.status {
        case .snoozed: return "Snoozed today · no routine"
        case .runningLate: return "Up late today · no routine"
        case .silentLate: return "Missed today · no routine"
        default: return nil
        }
    }

    /// The Start habit / Start checklist button. Returns whether a routine started.
    @discardableResult
    static func startFromCard(group: RTGroup, habit: MemberHabit, now: Date = Date()) async -> Bool {
        guard startableUntil(group: group, habit: habit, now: now) != nil,
              let me = group.roster.first(where: { $0.isYou }) else { return false }
        RoutineLog.add("Start button → open \(habit.kindNoun) for \(group.id)")
        await RoutineCoordinator.shared.begin(groupId: group.id, groupName: group.name, habit: habit,
                                              uid: me.uid, alarmFiredAt: todaysFire(group: group, now: now) ?? now)
        RoutineCoordinator.shared.presentRoutine = true
        return true
    }
}
