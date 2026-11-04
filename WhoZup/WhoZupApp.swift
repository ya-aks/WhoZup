//
//  WhoZupApp.swift
//  WhoZup
//
//  Created by akshay yadav on 21/06/26.
//

import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import SwiftUI
import SwiftData

@main
struct WhoZupApp: App {
    // Adopts a UIKit app delegate so the APNs device token is forwarded to FCM
    // (see AppDelegate in AppFCM.swift). SwiftUI apps otherwise have none.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    private let alarmScheduler: AlarmScheduler
    @StateObject private var alarmStatusRecorder: AlarmStatusRecorder
    // No default value: AuthManager touches Firebase and must only be
    // constructed after FirebaseApp.configure() runs in init below.
    @State private var authManager: AuthManager
    // Lives above the signed-in/signed-out switch so an invite link tapped
    // while logged out survives sign-in and resumes afterwards.
    @State private var pendingInvite = PendingInviteStore()

    init() {
        // IMPORTANT: do NOT touch Firebase/Auth here. SwiftUI runs `App.init()`
        // before `UIApplication.shared` exists, and FirebaseAuth only sets up its
        // APNs `tokenManager` + app-delegate swizzling if the shared application
        // is available at `Auth`'s first initialization. Configuring here left
        // `tokenManager` nil and crashed phone-number sign-in. All Firebase setup
        // now happens in the root `.task` below, once the app is running.
        _authManager = State(initialValue: AuthManager())

        let recorder = AlarmStatusRecorder()
        alarmScheduler = AlarmScheduler()
        _alarmStatusRecorder = StateObject(wrappedValue: recorder)
        // AlarmKit only — no Firebase — so it's safe this early.
        recorder.startObserving()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.user != nil {
                    RTRootView()
                        .fullScreenCover(isPresented: Binding(
                            get: { authManager.needsNameSetup },
                            set: { _ in }
                        )) {
                            RTNameSetupSheet()
                        }
                } else {
                    AuthView()
                }
            }
            .environment(authManager)
            .environment(pendingInvite)
            .environment(PendingGroupStore.shared)
            .environmentObject(alarmStatusRecorder)
            .environment(\.alarmScheduler, alarmScheduler)
            // Configure Firebase and make the first Auth access here — this runs
            // once, after the scene appears, when `UIApplication.shared` and the
            // app delegate are ready. That lets FirebaseAuth initialize its APNs
            // `tokenManager` and register its swizzling, which is what makes
            // phone-number verification work (and stops it crashing on a nil
            // token). Must not move back into `App.init()`.
            .task {
                FirebaseBootstrap.ensureConfigured()
                authManager.start()
                // Push registration + APNs token forwarding to Auth/Messaging.
                AppFCM.shared.start()
                // Start the purchase-updates listener from launch.
                _ = EventPackStore.shared
            }
            // The whoZup UI uses a fixed warm/light palette; force light so
            // system controls (text fields, date pickers) don't invert their
            // text color against the cream background in Dark Mode.
            .preferredColorScheme(.light)
            .onOpenURL { url in
                // Google Sign-In (and the phone-auth reCAPTCHA) round-trips
                // back through a custom scheme; an invite arrives as an https
                // Universal Link. Only one of the three can claim any given URL.
                // FirebaseAuth's reCAPTCHA callback (the encoded-app-id scheme,
                // used when a silent push can't verify — e.g. on the simulator)
                // must be handed to Auth first or phone sign-in never completes.
                if Auth.auth().canHandle(url) { return }
                // "Open routine" on the lock-screen Live Activity.
                if RoutineLink.matches(url) {
                    RoutineCoordinator.shared.presentIfOpen()
                    return
                }
                if GIDSignIn.sharedInstance.handle(url) { return }
                if let code = InviteLink.code(from: url) {
                    pendingInvite.set(code)
                }
            }
            // Universal Links reach a SwiftUI app as a browsing user activity.
            // Handled alongside onOpenURL because which one fires depends on
            // whether the app was already running.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL, let code = InviteLink.code(from: url) {
                    pendingInvite.set(code)
                }
            }
        }
        .modelContainer(sharedModelContainer)
    }
}

private struct AlarmSchedulerKey: EnvironmentKey {
    static let defaultValue = AlarmScheduler()
}

extension EnvironmentValues {
    var alarmScheduler: AlarmScheduler {
        get { self[AlarmSchedulerKey.self] }
        set { self[AlarmSchedulerKey.self] = newValue }
    }
}
