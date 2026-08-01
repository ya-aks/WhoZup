//
//  AuthView.swift
//  WhoZup
//
//  whoZup sign-in: Continue with Apple / Google / Phone, plus a custom phone
//  entry + SMS-code flow with an on-screen keypad. Google and Phone are wired
//  to the live AuthManager; Apple uses Sign in with Apple (needs the capability
//  + Firebase Apple provider enabled to succeed at runtime).
//

import AuthenticationServices
import SwiftUI

struct AuthView: View {
    @Environment(AuthManager.self) private var authManager

    private enum Stage { case choices, phone, code }
    @State private var stage: Stage = .choices
    @State private var phoneDigits = ""
    @State private var codeDigits = ""
    @State private var country: PhoneCountry = .default
    @State private var showCountryPicker = false

    var body: some View {
        ZStack {
            RT.canvas.ignoresSafeArea()
            switch stage {
            case .choices: choices
            case .phone: phoneEntry
            case .code: codeEntry
            }
        }
        .animation(.easeInOut(duration: 0.25), value: stage)
        .onChange(of: authManager.isAwaitingPhoneCode) { _, awaiting in
            if awaiting { stage = .code }
        }
    }

    // MARK: - Choices

    private var choices: some View {
        VStack(spacing: 0) {
            Spacer()

            Image("whozup-logo")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color(hex: "#d98c3a").opacity(0.25), radius: 14, y: 8)

            logo.padding(.top, 24)

            Text("Wake up together, show up together — one group, everyone accountable.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(RT.inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 260)
                .padding(.top, 8)

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.continue) { request in
                    authManager.configureAppleRequest(request)
                } onCompletion: { result in
                    Task { await authManager.completeAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                providerButton(
                    title: "Continue with Google",
                    icon: googleGlyph,
                    background: RT.card,
                    foreground: RT.ink,
                    border: Color(hex: "#e5ddcc")
                ) {
                    Task { await authManager.signInWithGoogle() }
                }

                providerButton(
                    title: "Continue with phone",
                    icon: AnyView(Image(systemName: "phone.fill").foregroundStyle(Color(hex: "#3f6fa3"))),
                    background: RT.card,
                    foreground: RT.ink,
                    border: Color(hex: "#e5ddcc")
                ) {
                    stage = .phone
                }
            }

            if authManager.isWorking {
                ProgressView().padding(.top, 14)
            }
            if let error = authManager.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }

            Text("By continuing you agree to our\nTerms of Service & Privacy Policy.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(RT.inkFaint)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 22)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 34)
    }

    private var logo: some View {
        (Text("who") + Text("Z").foregroundColor(Color(hex: "#d98c3a")) + Text("up"))
            .font(.system(size: 36, weight: .heavy))
            .foregroundStyle(RT.ink)
    }

    private var googleGlyph: AnyView {
        AnyView(
            Text("G")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Color(hex: "#4285F4"))
        )
    }

    private func providerButton(title: String, icon: AnyView, background: Color, foreground: Color, border: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                Text(title).font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(border, lineWidth: 1))
        }
        .buttonStyle(RTPressStyle())
        .disabled(authManager.isWorking)
    }

    // MARK: - Phone entry

    private var phoneEntry: some View {
        VStack(alignment: .leading, spacing: 0) {
            backButton { stage = .choices }

            Text("Enter your phone")
                .font(.rtDisplay(27, .bold))
                .foregroundStyle(RT.ink)
                .padding(.top, 22)

            Text("We'll text a code to verify it's you.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RT.inkMuted)
                .padding(.top, 5)

            HStack(spacing: 12) {
                Button { showCountryPicker = true } label: {
                    HStack(spacing: 5) {
                        Text(country.flag).font(.system(size: 24))
                        Text(country.dialCode).font(.rtDisplay(26, .bold)).foregroundStyle(RT.ink)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(RT.inkMuted)
                    }
                }
                .buttonStyle(.plain)
                Text(phoneDigits.isEmpty ? country.placeholder : PhoneCountry.group(phoneDigits))
                    .font(.rtDisplay(26, .bold))
                    .foregroundStyle(phoneDigits.isEmpty ? Color(hex: "#cbc2b0") : RT.ink)
                Spacer()
            }
            .padding(.top, 26)
            .padding(.bottom, 14)
            .overlay(Rectangle().fill(Color(hex: "#e2dccf")).frame(height: 2), alignment: .bottom)

            Spacer()

            Button {
                Task { await authManager.startPhoneVerification(phoneNumber: "\(country.dialCode)\(phoneDigits)") }
            } label: {
                primaryLabel(authManager.isWorking ? "Sending…" : "Continue")
            }
            .disabled(phoneDigits.count < country.digits || authManager.isWorking)
            .opacity(phoneDigits.count < country.digits ? 0.5 : 1)

            if let error = authManager.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.top, 8)
            }

            RTKeypad(
                onDigit: { if phoneDigits.count < country.digits { phoneDigits.append($0) } },
                onDelete: { if !phoneDigits.isEmpty { phoneDigits.removeLast() } }
            )
            .padding(.top, 18)
        }
        .padding(.horizontal, 26)
        .padding(.top, 66)
        .padding(.bottom, 34)
        .sheet(isPresented: $showCountryPicker) {
            CountryPickerSheet(selection: $country)
                .onDisappear { if phoneDigits.count > country.digits { phoneDigits = String(phoneDigits.prefix(country.digits)) } }
        }
    }

    // MARK: - Code entry

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 0) {
            backButton {
                authManager.cancelPhoneVerification()
                codeDigits = ""
                stage = .phone
            }

            Text("Enter the code")
                .font(.rtDisplay(27, .bold))
                .foregroundStyle(RT.ink)
                .padding(.top, 22)

            Text("Sent to \(country.dialCode) \(PhoneCountry.group(phoneDigits))")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RT.inkMuted)
                .padding(.top, 5)

            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    let char = i < codeDigits.count ? String(Array(codeDigits)[i]) : ""
                    Text(char)
                        .font(.rtDisplay(24, .heavy))
                        .foregroundStyle(RT.ink)
                        .frame(width: 46, height: 56)
                        .background(RoundedRectangle(cornerRadius: 12).fill(RT.card))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(i == codeDigits.count ? Color(hex: "#3f6fa3") : RT.cardBorder, lineWidth: 2))
                }
            }
            .padding(.top, 26)

            if authManager.isWorking {
                HStack { ProgressView(); Text("Verifying…").foregroundStyle(RT.inkMuted) }
                    .padding(.top, 14)
            }
            if let error = authManager.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.top, 10)
            }

            Spacer()

            RTKeypad(
                onDigit: { digit in
                    guard codeDigits.count < 6 else { return }
                    codeDigits.append(digit)
                    if codeDigits.count == 6 {
                        Task { await authManager.confirmPhoneCode(codeDigits) }
                    }
                },
                onDelete: { if !codeDigits.isEmpty { codeDigits.removeLast() } }
            )
            .padding(.top, 18)
        }
        .padding(.horizontal, 26)
        .padding(.top, 66)
        .padding(.bottom, 34)
    }

    // MARK: - Shared bits

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text("‹").font(.system(size: 20))
                Text("Back").font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color(hex: "#3f6fa3"))
        }
        .buttonStyle(.plain)
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(RT.ink))
    }

}

/// Reusable numeric keypad (1–9, 0, delete).
struct RTKeypad: View {
    let onDigit: (String) -> Void
    let onDelete: () -> Void

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 11), count: 3), spacing: 11) {
            ForEach(keys, id: \.self) { key in
                if key.isEmpty {
                    Color.clear.frame(height: 56)
                } else {
                    Button {
                        if key == "⌫" { onDelete() } else { onDigit(key) }
                    } label: {
                        Text(key)
                            .font(.rtDisplay(24, .semibold))
                            .foregroundStyle(RT.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(RTPressStyle())
                }
            }
        }
    }
}

#Preview {
    AuthView()
        .environment(AuthManager())
}
