//
//  AuthManager.swift
//  WhoZup
//
//  Firebase Authentication wrapper supporting Email/Password, Google
//  Sign-In, and Phone (SMS) sign-in, plus creation of the user's Firestore
//  profile document (`users/{uid}`) on first sign-in.
//
//  Must not be constructed before `FirebaseApp.configure()` has run —
//  `WhoZupApp.init` guarantees that ordering.
//

import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseMessaging
import Foundation
import GoogleSignIn
import UIKit
import os.log

@MainActor
@Observable
public final class AuthManager {
    /// The currently signed-in Firebase user, or `nil` when signed out.
    public private(set) var user: FirebaseAuth.User?
    /// True while a sign-in/sign-up call is in flight.
    public private(set) var isWorking = false
    /// The most recent auth error, for display. Cleared on the next attempt.
    public private(set) var errorMessage: String?
    /// Set after `startPhoneVerification` succeeds; cleared after sign-in.
    public private(set) var isAwaitingPhoneCode = false

    /// Set when the user needs to enter their first and last name.
    public private(set) var needsNameSetup = false
    public private(set) var firstName = ""
    public private(set) var lastName = ""

    /// Clears any pending error. The sign-in screens share one error field, so
    /// navigating between the choices/phone/code stages must reset it —
    /// otherwise an error raised on one stage bleeds onto the next.
    public func clearError() {
        errorMessage = nil
    }

    @ObservationIgnored private var authStateHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var phoneVerificationID: String?
    private let logger = Logger(subsystem: "com.whozup.WhoZup", category: "AuthManager")

    // Firestore.firestore() returns a cached instance; computed access keeps
    // this safe even though AuthManager itself must already be constructed
    // after FirebaseApp.configure().
    private var db: Firestore { Firestore.firestore() }

    public init() {}

    /// Begins observing Firebase auth state. Deliberately separate from `init`:
    /// the very first `Auth.auth()` access is what makes FirebaseAuth initialize
    /// its APNs `tokenManager` and register its app-delegate swizzling, and that
    /// only works once `UIApplication.shared` exists. `WhoZupApp.init()` runs
    /// before that, so this is called later (from the app's root `.task`) to keep
    /// phone-number sign-in from crashing on a nil `tokenManager`.
    public func start() {
        guard authStateHandle == nil else { return }
        user = Auth.auth().currentUser
        if user != nil {
            Task { await self.checkUserProfile() }
        }
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                if user != nil {
                    await self?.checkUserProfile()
                } else {
                    self?.needsNameSetup = false
                }
            }
        }
    }

    deinit {
        if let authStateHandle {
            Auth.auth().removeStateDidChangeListener(authStateHandle)
        }
    }

    // MARK: - Email/password

    public func signUp(email: String, password: String) async {
        await run {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            try await self.ensureUserProfile(for: result.user)
        }
    }

    public func signIn(email: String, password: String) async {
        await run {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            try await self.ensureUserProfile(for: result.user)
        }
    }

    // MARK: - Sign in with Apple
    //
    // Requires the "Sign in with Apple" capability on the target and the Apple
    // provider enabled in Firebase Console → Authentication. The code compiles
    // and runs without those, but sign-in only succeeds once they're set up.

    @ObservationIgnored private var appleNonce: String?

    /// Configure the Apple request (scopes + hashed nonce). Call from
    /// `SignInWithAppleButton`'s `onRequest`.
    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        appleNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Complete Apple sign-in. Call from `SignInWithAppleButton`'s `onCompletion`.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        await run {
            switch result {
            case .failure(let error):
                throw error
            case .success(let authorization):
                guard
                    let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                    let nonce = self.appleNonce,
                    let tokenData = credential.identityToken,
                    let idToken = String(data: tokenData, encoding: .utf8)
                else {
                    throw AuthError.missingIDToken
                }
                let firebaseCredential = OAuthProvider.appleCredential(
                    withIDToken: idToken,
                    rawNonce: nonce,
                    fullName: credential.fullName
                )
                let authResult = try await Auth.auth().signIn(with: firebaseCredential)
                try await self.ensureUserProfile(for: authResult.user)
            }
        }
    }

    // MARK: - Google Sign-In

    public func signInWithGoogle() async {
        await run {
            guard let clientID = FirebaseApp.app()?.options.clientID else {
                throw AuthError.missingClientID
            }
            guard let presenter = Self.rootViewController() else {
                throw AuthError.noPresenter
            }

            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)

            guard let idToken = signInResult.user.idToken?.tokenString else {
                throw AuthError.missingIDToken
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: signInResult.user.accessToken.tokenString
            )
            let result = try await Auth.auth().signIn(with: credential)
            try await self.ensureUserProfile(for: result.user)
        }
    }

    // MARK: - Phone

    /// Sends an SMS verification code to `phoneNumber` (E.164, e.g. +91...).
    public func startPhoneVerification(phoneNumber: String) async {
        logger.log("startPhoneVerification: requesting code for \(phoneNumber, privacy: .private(mask: .hash))")
        let hasAPNS = Auth.auth().apnsToken != nil
        logger.log("startPhoneVerification: FirebaseAuth apnsToken present=\(hasAPNS, privacy: .public), registered=\(UIApplication.shared.isRegisteredForRemoteNotifications, privacy: .public)")
        await run {
            let verificationID = try await PhoneAuthProvider.provider()
                .verifyPhoneNumber(phoneNumber, uiDelegate: nil)
            self.logger.log("startPhoneVerification: received verificationID (len=\(verificationID.count, privacy: .public)) — SMS should be sent")
            self.phoneVerificationID = verificationID
            self.isAwaitingPhoneCode = true
        }
    }

    /// Completes phone sign-in with the SMS code the user received.
    public func confirmPhoneCode(_ code: String) async {
        await run {
            guard let verificationID = self.phoneVerificationID else {
                throw AuthError.noPendingPhoneVerification
            }
            let credential = PhoneAuthProvider.provider().credential(
                withVerificationID: verificationID,
                verificationCode: code
            )
            self.logger.log("confirmPhoneCode: verifying 6-digit code")
            let result = try await Auth.auth().signIn(with: credential)
            self.logger.log("confirmPhoneCode: sign-in succeeded uid=\(result.user.uid, privacy: .private(mask: .hash))")
            self.phoneVerificationID = nil
            self.isAwaitingPhoneCode = false
            try await self.ensureUserProfile(for: result.user)
        }
    }

    public func cancelPhoneVerification() {
        phoneVerificationID = nil
        isAwaitingPhoneCode = false
    }

    // MARK: - Sign out

    public func signOut() async {
        // Stop this device from receiving pushes for the account that's leaving.
        // Delete the FCM token doc FIRST, while still authenticated (security
        // rules only allow a user to write their own `fcmTokens/{uid}`), so the
        // notification Cloud Functions no longer have a token to target. Then
        // invalidate the on-device token so a fresh one is minted for whoever
        // signs in next. Both are best-effort — never block sign-out on them.
        if let uid = Auth.auth().currentUser?.uid {
            try? await db.collection("fcmTokens").document(uid).delete()
        }
        try? await Messaging.messaging().deleteToken()
        await clearLocalAccountState()
        do {
            GIDSignIn.sharedInstance.signOut()
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Leaves nothing of the outgoing account behind on the device, so whoever
    /// signs in next starts clean and nothing is ever written on the old
    /// account's behalf:
    ///  - gives any queued offline writes (an alarm response, say) a bounded
    ///    chance to reach the server first. Firestore keeps unsent writes per
    ///    account, so anything still queued stays on the phone and only goes out
    ///    when this same account signs in here again — never under someone else;
    ///  - cancels this account's AlarmKit alarms and forgets their records.
    private func clearLocalAccountState() async {
        await AlarmActionHandler.confirmPendingWrites(db: db, timeout: .seconds(3))
        RTAlarmSync.removeAllAlarms()
    }

    // MARK: - Delete account

    /// Deletes the signed-in Firebase Auth user. Call **after**
    /// `GroupRepository.deleteAccountData()` has removed their Firestore data
    /// (that requires auth). Returns whether the account was deleted.
    ///
    /// Firebase requires a recent sign-in to delete an account; if the session is
    /// too old this surfaces a clear message asking the user to sign in again and
    /// retry, rather than failing silently.
    public func deleteAccount() async -> Bool {
        guard let user = Auth.auth().currentUser else { return false }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        try? await Messaging.messaging().deleteToken()
        do {
            try await user.delete()
            // Only once the account is really gone: a failed delete leaves the
            // user signed in, and their alarms must keep working.
            RTAlarmSync.removeAllAlarms()
            GIDSignIn.sharedInstance.signOut()
            return true
        } catch {
            let ns = error as NSError
            if ns.code == AuthErrorCode.requiresRecentLogin.rawValue {
                errorMessage = "For your security, please sign out and sign in again, then delete your account."
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    // MARK: - Firestore profile & Name Setup

    public static func parseNames(email: String?, displayName: String?) -> (firstName: String, lastName: String) {
        if let displayName = displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty, displayName != "Member", displayName != "You" {
            let parts = displayName.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            if let first = parts.first {
                let last = parts.dropFirst().joined(separator: " ")
                return (first, last)
            }
        }
        
        if let email = email, !email.isEmpty {
            let emailSub = Substring(email)
            let localSub = emailSub.split(separator: "@").first ?? ""
            let cleanSub = localSub.split(separator: "+").first ?? localSub
            let cleanLocal = String(cleanSub)
            let separators = CharacterSet(charactersIn: "._-")
            let components = cleanLocal.components(separatedBy: separators).filter { !$0.isEmpty }
            if components.count >= 2 {
                let first = components[0].capitalized
                let lastComponents = components.dropFirst().map { $0.capitalized }
                let last = lastComponents.joined(separator: " ")
                return (first, last)
            } else if let first = components.first {
                return (first.capitalized, "")
            }
        }
        
        return ("", "")
    }

    public func checkUserProfile() async {
        guard let user = Auth.auth().currentUser else {
            needsNameSetup = false
            return
        }
        let ref = db.collection("users").document(user.uid)
        do {
            let snapshot = try await ref.getDocument()
            if snapshot.exists, let data = snapshot.data() {
                let fn = data["firstName"] as? String ?? ""
                let ln = data["lastName"] as? String ?? ""
                let dn = data["displayName"] as? String ?? ""
                
                if !fn.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.firstName = fn
                    self.lastName = ln
                    self.needsNameSetup = false
                } else if !dn.trimmingCharacters(in: .whitespaces).isEmpty && dn != "Member" && dn != "You" {
                    let parsed = Self.parseNames(email: user.email, displayName: dn)
                    self.firstName = parsed.firstName
                    self.lastName = parsed.lastName
                    self.needsNameSetup = parsed.firstName.isEmpty
                } else {
                    let parsed = Self.parseNames(email: user.email, displayName: user.displayName)
                    self.firstName = parsed.firstName
                    self.lastName = parsed.lastName
                    self.needsNameSetup = true
                }
            } else {
                let parsed = Self.parseNames(email: user.email, displayName: user.displayName)
                self.firstName = parsed.firstName
                self.lastName = parsed.lastName
                self.needsNameSetup = true
            }
        } catch {
            let parsed = Self.parseNames(email: user.email, displayName: user.displayName)
            self.firstName = parsed.firstName
            self.lastName = parsed.lastName
            self.needsNameSetup = true
        }
    }

    public func saveUserProfile(firstName: String, lastName: String) async throws {
        guard let user = Auth.auth().currentUser else { return }
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        let trimmedLast = lastName.trimmingCharacters(in: .whitespaces)
        guard !trimmedFirst.isEmpty else {
            throw NSError(domain: "AuthManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "First name is mandatory."])
        }
        
        let combinedName = trimmedLast.isEmpty ? trimmedFirst : "\(trimmedFirst) \(trimmedLast)"
        
        let changeRequest = user.createProfileChangeRequest()
        changeRequest.displayName = combinedName
        try await changeRequest.commitChanges()
        
        let ref = db.collection("users").document(user.uid)
        var data: [String: Any] = [
            "firstName": trimmedFirst,
            "lastName": trimmedLast,
            "displayName": combinedName,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let email = user.email { data["email"] = email }
        if let phone = user.phoneNumber { data["phoneNumber"] = phone }
        
        try await ref.setData(data, merge: true)
        
        self.firstName = trimmedFirst
        self.lastName = trimmedLast
        self.needsNameSetup = false
        RTAnalytics.profileCompleted()
    }

    /// Creates `users/{uid}` on first sign-in. Field shapes must stay in
    /// sync with firestore.rules (`isValidUser`).
    /// phone, google, apple or email, from the account's first provider.
    private static func analyticsMethod(_ user: FirebaseAuth.User) -> String {
        switch user.providerData.first?.providerID {
        case "phone": return "phone"
        case "google.com": return "google"
        case "apple.com": return "apple"
        case "password": return "email"
        default: return user.providerData.first?.providerID ?? "unknown"
        }
    }

    private func ensureUserProfile(for user: FirebaseAuth.User) async throws {
        let ref = db.collection("users").document(user.uid)
        let snapshot = try await ref.getDocument()
        RTAnalytics.signedIn(method: Self.analyticsMethod(user), isNew: !snapshot.exists)
        if !snapshot.exists {
            let parsed = Self.parseNames(email: user.email, displayName: user.displayName)
            var displayName = user.displayName
                ?? (parsed.firstName.isEmpty ? nil : (parsed.lastName.isEmpty ? parsed.firstName : "\(parsed.firstName) \(parsed.lastName)"))
                ?? user.email.map { String($0.split(separator: "@")[0]) }
                ?? "Member"
            displayName = String(displayName.prefix(50))
            if displayName.isEmpty { displayName = "Member" }

            var data: [String: Any] = [
                "displayName": displayName,
                "firstName": parsed.firstName,
                "lastName": parsed.lastName,
                "createdAt": FieldValue.serverTimestamp(),
            ]
            if let email = user.email { data["email"] = email }
            if let phone = user.phoneNumber { data["phoneNumber"] = phone }

            try await ref.setData(data, merge: true)
            logger.log("Created Firestore profile for uid \(user.uid, privacy: .private)")
        }
        await checkUserProfile()
    }

    // MARK: - Helpers

    private func run(_ operation: @MainActor () async throws -> Void) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            let ns = error as NSError
            logger.error("""
            Auth operation failed: domain=\(ns.domain, privacy: .public) \
            code=\(ns.code, privacy: .public) \
            desc=\(ns.localizedDescription, privacy: .public) \
            userInfo=\(String(describing: ns.userInfo), privacy: .public)
            """)
            #if DEBUG
            // Surface the exact FirebaseAuth error code on-screen in debug builds
            // so the failure is diagnosable on a physical device without a log
            // stream. Release builds keep the plain, user-friendly message.
            errorMessage = "[\(ns.domain) \(ns.code)] \(ns.localizedDescription)"
            #else
            errorMessage = error.localizedDescription
            #endif
        }
    }

    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?
            .rootViewController
    }

    enum AuthError: LocalizedError {
        case missingClientID
        case noPresenter
        case missingIDToken
        case noPendingPhoneVerification

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "Firebase is not configured with a Google OAuth client."
            case .noPresenter:
                return "No view controller available to present sign-in."
            case .missingIDToken:
                return "Google sign-in did not return an ID token."
            case .noPendingPhoneVerification:
                return "No phone verification in progress — request a code first."
            }
        }
    }

    // MARK: - Nonce helpers (Sign in with Apple)

    private static func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
