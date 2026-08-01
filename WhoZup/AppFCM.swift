//
//  AppFCM.swift
//  WhoZup
//
//  Firebase Cloud Messaging registration (scaffold for push notifications).
//
//  This registers the device for remote notifications and uploads the FCM
//  token to `fcmTokens/{uid}` so the alarm-change Cloud Function can target it.
//
//  NOT ACTIVE until you finish the APNs setup:
//    1. Add the "Push Notifications" capability to the WhoZup target in Xcode
//       (adds the aps-environment entitlement).
//    2. Upload an APNs Auth Key (.p8) in Firebase Console → Project settings →
//       Cloud Messaging → Apple app configuration.
//    3. Deploy the Cloud Functions (see functions/index.js).
//
//  Until then this compiles and runs harmlessly: on the simulator or without
//  the entitlement, APNs registration simply fails and no token is uploaded.
//

import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import Foundation
import UIKit
import os.log

@MainActor
final class AppFCM: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate {
    static let shared = AppFCM()

    private let logger = Logger(subsystem: "com.whozup.WhoZup", category: "AppFCM")

    /// Call once after `FirebaseApp.configure()`. Sets delegates and asks the
    /// system to register for remote notifications.
    func start() {
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // MARK: - MessagingDelegate

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in
            await self.uploadToken(fcmToken)
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
