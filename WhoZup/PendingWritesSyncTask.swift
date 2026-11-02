//
//  PendingWritesSyncTask.swift
//  WhoZup
//
//  Gets offline alarm responses to the server once the network is back, even
//  if the app isn't opened again.
//
//  An alarm answered offline is written to Firestore's on-disk queue straight
//  away, but Firestore only sends that queue while the app's process is
//  running. iOS has no "network came back" wake-up for apps, so the closest
//  mechanism is a BGProcessingTask with `requiresNetworkConnectivity`: iOS only
//  launches it when the device is online, and the handler just starts Firestore
//  and waits for the queue to drain. iOS still decides *when* (usually while the
//  phone is idle), so this narrows the gap rather than guaranteeing a time —
//  opening the app, or the background refresh task, also flushes the queue.
//

import BackgroundTasks
import FirebaseAuth
import FirebaseFirestore
import Foundation
import os.log

enum PendingWritesSyncTask {
    static let identifier = "com.whozup.syncPending"
    private static let logger = Logger(subsystem: "com.whozup.WhoZup", category: "BGSync")

    /// Registers the handler. Must run before launch completes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(processing)
        }
    }

    /// Asks iOS to run a sync the next time the device is online. Cheap and
    /// idempotent: resubmitting replaces the pending request, and a run with an
    /// empty queue finishes immediately. Called when backgrounding and whenever
    /// a response couldn't be confirmed as synced.
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to schedule BG sync: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        let work = Task { @MainActor in
            let synced = await flush(timeout: .seconds(25))
            // Still unsent (flaky network, or iOS cut us short): try again later.
            if !synced { schedule() }
            task.setTaskCompleted(success: synced)
        }
        task.expirationHandler = {
            work.cancel()
            schedule()
        }
    }

    /// Starts Firestore for the signed-in user and waits up to `timeout` for
    /// every queued write to be acknowledged. Returns whether the queue drained.
    /// Firestore keeps a separate queue per account and only sends the signed-in
    /// account's, so there's nothing to do while signed out.
    @MainActor
    static func flush(timeout: Duration) async -> Bool {
        FirebaseBootstrap.ensureConfigured()
        guard Auth.auth().currentUser != nil else { return true }
        let synced = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await Firestore.firestore().waitForPendingWrites()) != nil }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        logger.log("Background sync \(synced ? "completed" : "timed out", privacy: .public)")
        return synced
    }
}
