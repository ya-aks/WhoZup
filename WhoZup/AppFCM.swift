//
//  AppFCM.swift
//  WhoZup
//
//  Firebase Cloud Messaging registration (scaffold for push notifications).
//
//  This registers the device for remote notifications and uploads the FCM
//  token to `fcmTokens/{uid}` so the alarm-change Cloud Function can target it.
//
//  APNs setup checklist (all now in place):
//    1. "Push Notifications" capability on the WhoZup target → `aps-environment`
//       entitlement (WhoZup.entitlements). This MUST match the build's signing:
//       `development` for debug/run-from-Xcode on device (APNs sandbox),
//       `production` for Archive/TestFlight/App Store. A debug build signed with
//       a Development profile but carrying `production` fails registration with
//       "no valid aps-environment entitlement", so no APNs token is ever issued.
//       Pair with a .p8 APNs Auth Key in Firebase (works for BOTH environments).
//    2. An APNs Auth Key (.p8) or certificate uploaded in Firebase Console →
//       Project settings → Cloud Messaging → Apple app configuration.
//    3. The Cloud Functions deployed (see functions/index.js) — they are the
//       sender side that pushes to these tokens.
//
//  Token forwarding: `AppDelegate` below hands the raw APNs device token to
//  `Messaging.messaging().apnsToken` so FCM can mint a registration token even
//  without relying on Firebase's app-delegate swizzling. On the simulator or
//  without the entitlement, APNs registration simply fails and no token is
//  uploaded — harmless.
//

import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import Foundation
import UIKit
import os.log

/// Set when a notification is tapped, so the UI can deep-link to that group.
/// A shared singleton because the tap is handled in `AppFCM` (outside SwiftUI);
/// `RTRootView`/`RTGroupListView` observe it and push the group's detail.
@MainActor
@Observable
final class PendingGroupStore {
    static let shared = PendingGroupStore()
    var groupId: String?
    private init() {}
}

@MainActor
final class AppFCM: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate {
    static let shared = AppFCM()

    private let logger = Logger(subsystem: "com.whozup.WhoZup", category: "AppFCM")

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    /// Call once after `FirebaseApp.configure()`. Sets delegates and asks the
    /// system to register for remote notifications.
    func start() {
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self

        // `start()` runs at launch, before sign-in, so the first registration
        // token arrives with no `uid` and can't be written. FCM won't re-emit
        // an unchanged token later, so re-fetch and upload it whenever a user
        // signs in. Mirrors WhoZupApplication.observeAuth() on Android.
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard user != nil else { return }
            Task { @MainActor in await self?.refreshAndUploadToken() }
        }

        // Register the event RSVP category with NO action buttons. The custom
        // notification content extension (WhoZupNotifications) renders the full
        // Coming/Can't + late-ETA grid on expand, so registering standard actions
        // too would show the options twice — iOS draws a category's action
        // buttons *below* a content extension. The category id still must be
        // registered so the extension binds to it and the tap handler runs.
        // (The RSVP action identifiers are still handled in didReceive for any
        // older notification already sitting in Notification Center.)
        registerNotificationHandling()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                self?.logger.error("Notification authorization error: \(error.localizedDescription, privacy: .public)")
            }
            self?.logger.log("Notification authorization granted=\(granted)")
        }

        // Register for remote notifications UNCONDITIONALLY — the APNs *device
        // token* is what FCM needs to mint a registration token, and it is
        // independent of whether the user granted the alert permission. Gating
        // this on `granted` meant a denied/dismissed prompt left the app with no
        // APNs token at all (FCM then logs I-FCM002022 and declines the token).
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Installs this object as the notification delegate and registers every
    /// category. Called from `didFinishLaunching` as well as `start()`: Apple
    /// requires the delegate to be set *before the app finishes launching*, or
    /// an action tapped while the app wasn't running (the alarm check-in's
    /// "I'm up") is never delivered — `start()` runs from SwiftUI's `.task`,
    /// which a background launch for a notification action never reaches.
    func registerNotificationHandling() {
        UNUserNotificationCenter.current().delegate = self
        let eventCategory = UNNotificationCategory(
            identifier: "EVENT_REMINDER_CATEGORY",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            eventCategory,
            AlarmCheckInNotifier.category,
        ])
    }

    // MARK: - MessagingDelegate

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in
            await self.uploadToken(fcmToken)
        }
    }

    /// Fetch the current FCM registration token and upload it. Used on sign-in,
    /// when the token itself hasn't changed but the signed-in `uid` has.
    func refreshAndUploadToken() async {
        do {
            let token = try await Messaging.messaging().token()
            await uploadToken(token)
        } catch {
            logger.error("Failed to fetch FCM token on auth change: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func uploadToken(_ token: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            try await Firestore.firestore().collection("fcmTokens").document(uid).setData([
                "token": token,
                "updatedAt": FieldValue.serverTimestamp(),
            ])
            logger.log("Uploaded FCM token for uid \(uid, privacy: .private)")
        } catch {
            logger.error("Failed to upload FCM token: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Foreground presentation

    // Main-actor isolated (no `nonisolated`): UserNotifications delivers these
    // delegate callbacks on the main thread and asserts "Call must be made on
    // main thread". Running them off the main actor crashes on notification tap.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - Response actions

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // The alarm "Did you wake up?" check-in has its own answers.
        if await AlarmCheckInNotifier.handle(response: response) { return }
        // "Start your routine" (no Live Activity could be shown): open it.
        if response.notification.request.content.userInfo["kind"] as? String == "routine" {
            RoutineCoordinator.shared.ensureLiveActivity()
            RoutineCoordinator.shared.presentRoutine = true
            return
        }

        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        guard let groupId = userInfo["groupId"] as? String else { return }

        // A plain tap on the notification body (not an action button) deep-links
        // to the group; the RSVP actions fall through to the switch below.
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            PendingGroupStore.shared.groupId = groupId
            return
        }

        let status: RTStatus
        var eta: String?
        switch actionIdentifier {
        case "COMING_ACTION":
            status = .coming
        // "LATE_ACTION" kept for backward compatibility with notifications posted
        // by an older build still in Notification Center.
        case "LATE_ACTION":
            status = .runningLate
        case "LATE_15_ACTION":
            status = .runningLate; eta = "+15"
        case "LATE_30_ACTION":
            status = .runningLate; eta = "+30"
        case "LATE_45_ACTION":
            status = .runningLate; eta = "+45"
        case "CANT_ACTION":
            status = .cantMakeIt
        default:
            return
        }

        let db = Firestore.firestore()
        guard let uid = Auth.auth().currentUser?.uid, !uid.isEmpty else { return }

        // Mirror GroupRepository.recordEventResponse so a notification RSVP and an
        // in-app RSVP write exactly the same status/detail/eta shape.
        let detail: String
        let verb: String
        switch status {
        case .coming:
            detail = "coming"
            verb = "is coming"
        case .runningLate:
            detail = eta.map { "ETA \($0)" } ?? "running late"
            verb = eta.map { "is running late (\($0))" } ?? "is running late"
        case .cantMakeIt:
            detail = "can't make it"
            verb = "can't make it"
        default:
            detail = ""
            verb = "responded"
        }

        var payload: [String: Any] = [
            "status": status.storageKey,
            "detail": detail,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let eta { payload["eta"] = eta }

        do {
            try await db.collection("groups").document(groupId)
                .collection("statuses").document(uid)
                .setData(payload)

            let userSnap = try await db.collection("users").document(uid).getDocument()
            let displayName = userSnap.data()?["displayName"] as? String ?? "Someone"

            let activityPayload: [String: Any] = [
                "actorUid": uid,
                "kind": "response",
                "message": "\(displayName) \(verb)",
                "timestamp": FieldValue.serverTimestamp()
            ]

            _ = try await db.collection("groups").document(groupId)
                .collection("activity")
                .addDocument(data: activityPayload)
            
            logger.log("Background RSVP action processed on iOS for event \(groupId)")
        } catch {
            logger.error("Failed to record background RSVP action on iOS: \(error.localizedDescription)")
        }
    }
}

/// Minimal UIKit app delegate, adopted via `@UIApplicationDelegateAdaptor` in
/// `WhoZupApp`. Its only job is to hand the raw APNs device token to FCM.
///
/// SwiftUI apps have no app delegate of their own, so without this the APNs
/// token reaches Messaging only through Firebase's method-swizzling. Forwarding
/// it explicitly makes registration-token generation deterministic.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "com.whozup.WhoZup", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Confirms the adaptor delegate is installed as UIApplication's delegate.
        logger.log("AppDelegate didFinishLaunching")
        // Register (must happen before launch completes) and schedule the
        // background sweep that persists skipped alarms as silent-late even when
        // the app is never opened.
        MissedAlarmBackgroundTask.register()
        MissedAlarmBackgroundTask.schedule()
        // Before launch completes, so a check-in answer tapped while the app was
        // closed reaches `didReceive` (no Firebase is touched here).
        AppFCM.shared.registerNotificationHandling()
        // An alarm answered on a phone not yet unlocked since reboot is journalled
        // but can't be written (no Keychain/UserDefaults yet); write it on unlock.
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AlarmReliability.sweep() }
        }
        // And the network-gated task that sends offline responses once the
        // device is back online, even if the app isn't reopened.
        PendingWritesSyncTask.register()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Ensure a sweep is queued for while the app is backgrounded.
        MissedAlarmBackgroundTask.schedule()
        // Anything still unsent goes out the next time the device is online.
        PendingWritesSyncTask.schedule()
        // A routine left unfinished keeps a way back in: its lock-screen card,
        // or a "Finish your routine" notification.
        Task { await RoutineCoordinator.shared.routineLeftOpen() }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.log("APNs device token received (\(deviceToken.count) bytes): \(hex, privacy: .private)")
        // FirebaseAuth and Messaging both receive this token via Firebase's
        // app-delegate swizzling, which is now correctly registered because Auth
        // is first initialized (in WhoZupApp's `.task`) after UIApplication is
        // ready. We deliberately do NOT call `Auth.setAPNSToken` here: an explicit
        // call previously crashed (nil `tokenManager` / `.unknown` assertion), and
        // it's unnecessary once swizzling is active. Messaging's explicit
        // assignment is kept as harmless belt-and-suspenders for push.
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Silent pushes for phone-auth verification arrive here. Hand them to
    /// FirebaseAuth first; only non-auth pushes fall through to the app.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let keys = userInfo.keys.map { "\($0)" }.sorted().joined(separator: ",")
        let handled = Auth.auth().canHandleNotification(userInfo)
        logger.log("didReceiveRemoteNotification: keys=[\(keys, privacy: .public)] consumedByAuth=\(handled, privacy: .public)")
        if handled {
            completionHandler(.noData)
            return
        }
        completionHandler(.noData)
    }
}
