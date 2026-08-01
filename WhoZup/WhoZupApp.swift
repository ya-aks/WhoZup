//
//  WhoZupApp.swift
//  WhoZup
//
//  Created by akshay yadav on 21/06/26.
//

import FirebaseCore
import GoogleSignIn
import SwiftUI
import SwiftData

@main
struct WhoZupApp: App {
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
        FirebaseApp.configure()
        _authManager = State(initialValue: AuthManager())

        let recorder = AlarmStatusRecorder()
        alarmScheduler = AlarmScheduler()
        _alarmStatusRecorder = StateObject(wrappedValue: recorder)
        recorder.startObserving()

        // Scaffolded push registration — harmless until APNs is configured.
        AppFCM.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.user != nil {
                    RTRootView()
                } else {
                    AuthView()
                }
            }
            .environment(authManager)
            .environment(pendingInvite)
            .environmentObject(alarmStatusRecorder)
            .environment(\.alarmScheduler, alarmScheduler)
            // The whoZup UI uses a fixed warm/light palette; force light so
            // system controls (text fields, date pickers) don't invert their
            // text color against the cream background in Dark Mode.
            .preferredColorScheme(.light)
            .onOpenURL { url in
                // Google Sign-In (and the phone-auth reCAPTCHA) round-trips
                // back through a custom scheme; an invite arrives as an https
                // Universal Link. Only one of the two can claim any given URL.
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
