//
//  MissedAlarmBackgroundTask.swift
//  WhoZup
//
//  Proactively marks *skipped* alarms silent-late even when the app is never
//  opened, using BGTaskScheduler.
//
//  A miss is otherwise only persisted when the app runs (launch/foreground
//  reconcile). AlarmKit gives no post-deadline callback, so without this a phone
//  that sits closed across the alarm's deadline never writes the outcome until
//  the user next opens the app. This registers a background-refresh task that
//  spins up a short-lived repository, lets the live data load, and runs the same
//  `reconcileMissedAlarms` the foreground path uses. Firestore's on-disk queue
//  makes the writes durable, so nothing is lost if connectivity is flaky.
//
//  iOS schedules background refresh opportunistically (timing isn't guaranteed),
//  so this complements — rather than replaces — the live roster's real-time
//  `MissedAlarm.isTodayMissed` derivation, which already shows the group a miss
//  the moment the deadline passes.
//

import BackgroundTasks
import FirebaseAuth
import FirebaseFirestore
import Foundation
import os.log

enum MissedAlarmBackgroundTask {
    static let identifier = "com.whozup.reconcileMissed"
    private static let logger = Logger(subsystem: "com.whozup.WhoZup", category: "BGReconcile")

    /// Registers the task handler. Must run before the app finishes launching,
    /// i.e. from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    /// Requests the next background run. Call on launch and when backgrounding;
    /// resubmitting simply replaces the pending request.
    /// `soonest`: ask to run right after this instead of in ~1h (a routine's
    /// deadline, so its lock-screen card comes down close to on time).
    static func schedule(soonest: Date? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // ~1h out; iOS decides the actual time based on usage patterns.
        let hourOut = Date(timeIntervalSinceNow: 60 * 60)
        request.earliestBeginDate = soonest.map { min($0, hourOut) } ?? hourOut
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to schedule BG reconcile: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Chain the next occurrence so the sweep keeps recurring.
        schedule()
        let work = Task { @MainActor in
            await runReconcile()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Bootstraps Firebase, loads the signed-in user's groups, and reconciles
    /// skipped alarms. Also callable directly (e.g. debug) — safe to run anytime.
    @MainActor
    static func runReconcile() async {
        FirebaseBootstrap.ensureConfigured()
        // Replay unwritten responses and top up check-in reminders first — these
        // need no repository, and keep the safety net alive while the app sits
        // unopened for days.
        await AlarmReliability.sweep()
        guard let user = Auth.auth().currentUser else { return }
        let name = user.displayName
            ?? user.email?.split(separator: "@").first.map(String.init)
            ?? "You"

        // A routine whose window closed while the app slept: take its card down.
        RoutineCoordinator.shared.expireIfNeeded()

        let repository = GroupRepository()
        repository.start(uid: user.uid, displayName: name)

        // Wait (bounded) for the group snapshot to arrive from cache/server,
        // then give the member/status listeners a moment to populate.
        for _ in 0..<16 where repository.groups.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(2))

        await repository.reconcileMissedAlarms()
        await confirmPendingWrites(timeout: .seconds(5))
        repository.stop()
        logger.log("Background missed-alarm reconcile completed")
    }

    /// Waits up to `timeout` for the queued silent-late writes to reach the
    /// server, then returns regardless — the local persistence already made them
    /// durable, so offline simply times out and syncs on the next connection.
    private static func confirmPendingWrites(timeout: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Firestore.firestore().waitForPendingWrites() }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
