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

    @ObservationIgnored private var authStateHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var phoneVerificationID: String?
    private let logger = Logger(subsystem: "com.whozup.WhoZup", category: "AuthManager")

    // Firestore.firestore() returns a cached instance; computed access keeps
    // this safe even though AuthManager itself must already be constructed
    // after FirebaseApp.configure().
    private var db: Firestore { Firestore.firestore() }

    public init() {
        user = Auth.auth().currentUser
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
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
        await run {
            let verificationID = try await PhoneAuthProvider.provider()
                .verifyPhoneNumber(phoneNumber, uiDelegate: nil)
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
            let result = try await Auth.auth().signIn(with: credential)
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

    public func signOut() {
        do {
            GIDSignIn.sharedInstance.signOut()
            try Auth.auth().signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Firestore profile

    /// Creates `users/{uid}` on first sign-in. Field shapes must stay in
    /// sync with firestore.rules (`isValidUser`).
    private func ensureUserProfile(for user: FirebaseAuth.User) async throws {
        let ref = db.collection("users").document(user.uid)
        let snapshot = try await ref.getDocument()
        guard !snapshot.exists else { return }

        var displayName = user.displayName
            ?? user.email.map { String($0.split(separator: "@")[0]) }
            ?? "Member"
        displayName = String(displayName.prefix(50))
        if displayName.isEmpty { displayName = "Member" }

        var data: [String: Any] = [
            "displayName": displayName,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let email = user.email { data["email"] = email }
        if let phone = user.phoneNumber { data["phoneNumber"] = phone }

        try await ref.setData(data)
        logger.log("Created Firestore profile for uid \(user.uid, privacy: .private)")
    }

    // MARK: - Helpers

    private func run(_ operation: @MainActor () async throws -> Void) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Auth operation failed: \(error.localizedDescription, privacy: .public)")
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
