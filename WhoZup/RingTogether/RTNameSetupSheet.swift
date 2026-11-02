//
//  RTNameSetupSheet.swift
//  WhoZup
//
//  Mandatory first name & optional last name entry sheet presented on sign-up / sign-in.
//  Prefills names from email or provider metadata when available.
//

import SwiftUI

struct RTNameSetupSheet: View {
    @Environment(AuthManager.self) private var authManager

    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFirstNameFocused: Bool

    var body: some View {
        ZStack {
            RT.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 12) {
                    Image("whozup-logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color(hex: "#d98c3a").opacity(0.2), radius: 10, y: 6)

                    Text("Welcome to whoZup")
                        .font(.rtDisplay(26, .bold))
                        .foregroundStyle(RT.ink)

                    Text("Tell your crew who's showing up. Enter your first and last name below.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 28)

                VStack(spacing: 16) {
                    // First Name (Mandatory)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("First Name")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RT.ink)
                            Text("* Mandatory")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: "#d98c3a"))
                        }

                        TextField("e.g. Alex", text: $firstName)
                            .focused($isFirstNameFocused)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RT.ink)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(firstName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.red.opacity(0.5) : RT.cardBorder, lineWidth: 1.5)
                            )
                    }

                    // Last Name (Optional)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Last Name")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(RT.ink)
                            Text("(Optional)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RT.inkMuted)
                        }

                        TextField("e.g. Smith", text: $lastName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(RT.ink)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(RT.cardBorder, lineWidth: 1.5)
                            )
                    }
                }
                .padding(.horizontal, 4)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 12)
                }

                Spacer()

                Button {
                    submitName()
                } label: {
                    HStack(spacing: 8) {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isSaving ? "Saving..." : "Continue")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(firstName.trimmingCharacters(in: .whitespaces).isEmpty ? RT.ink.opacity(0.4) : RT.ink)
                    )
                }
                .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                .buttonStyle(RTPressStyle())
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            if firstName.isEmpty {
                firstName = authManager.firstName
            }
            if lastName.isEmpty {
                lastName = authManager.lastName
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFirstNameFocused = true
            }
        }
    }

    private func submitName() {
        let trimmedFirst = firstName.trimmingCharacters(in: .whitespaces)
        guard !trimmedFirst.isEmpty else {
            errorMessage = "First name is mandatory."
            return
        }

        errorMessage = nil
        isSaving = true

        Task {
            do {
                try await authManager.saveUserProfile(firstName: trimmedFirst, lastName: lastName)
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

#Preview {
    RTNameSetupSheet()
        .environment(AuthManager())
}
