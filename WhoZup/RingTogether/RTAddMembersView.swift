//
//  RTAddMembersView.swift
//  WhoZup
//
//  The "Add members" screen: invite people by email/phone (composing a list to
//  share the code with), or show the QR + invite code to share directly. This
//  is used both after group creation and from a group's detail screen.
//
//  Note: there's no email/SMS-sending backend, so "adding" by email/phone
//  builds a share list; the actual join happens when the invitee uses the code,
//  QR, or link. The admin-only "join as admin" behavior is handled elsewhere.
//

import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Generates a QR code image from a string.
enum RTQR {
    static func image(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct RTAddMembersView: View {
    let code: String
    let groupName: String
    let accent: Color
    var adminToggle: Binding<Bool>?
    var onAdminToggleChange: ((Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(GroupRepository.self) private var repository

    private enum Mode { case addByContact, qrCode }
    @State private var mode: Mode = .addByContact
    @State private var input = ""
    @State private var invited: [InvitedContact] = []

    /// A Universal Link: taps straight into the join confirmation when the app
    /// is installed, and falls back to the web landing page when it isn't. The
    /// name and inviter are display hints for that page only — the app reads
    /// nothing but the code, and re-resolves everything from Firestore.
    private var joinURL: URL {
        InviteLink.url(code: code, groupName: groupName, invitedBy: repository.myDisplayName)
    }
    private var joinLink: String { joinURL.absoluteString }
    private var shareText: String {
        "Join “\(groupName)” on whoZup: \(joinLink)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Add members")
                        .font(.rtDisplay(28, .bold))
                        .foregroundStyle(RT.ink)

                    Text("Invite by email or text, or share a code.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(.top, 4)

                    modeTabs.padding(.top, 20)

                    if mode == .addByContact {
                        addByContact.padding(.top, 18)
                    } else {
                        qrCode.padding(.top, 20)
                    }

                    if let adminToggle {
                        adminToggleRow(adminToggle).padding(.top, 20)
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .background(RT.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle(groupName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 4) {
            tab("Email · Phone", active: mode == .addByContact) { mode = .addByContact }
            tab("QR · Code", active: mode == .qrCode) { mode = .qrCode }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(RT.cardBorderPressed))
    }

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(active ? RT.ink : RT.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 11).fill(active ? RT.card : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Add by email/phone

    private var addByContact: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField("Email or phone number", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(RT.cardBorder, lineWidth: 1))
                    .onSubmit(addContact)

                Button(action: addContact) {
                    Text("Add")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(accent))
                }
                .buttonStyle(RTPressStyle())
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if invited.isEmpty {
                Text("No one added yet.\nAdd people above, or share the code.")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color(hex: "#b1a892"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22)
            } else {
                Text("Invited · \(invited.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RT.inkSecondary)
                    .padding(.top, 20).padding(.leading, 4).padding(.bottom, 10)

                VStack(spacing: 0) {
                    ForEach(invited) { contact in
                        HStack(spacing: 12) {
                            RTAvatar(initials: contact.initials, color: accent, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.value)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(RT.ink)
                                    .lineLimit(1)
                                Text(contact.kindLabel)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(RT.inkFaint)
                            }
                            Spacer()
                            Button {
                                invited.removeAll { $0.id == contact.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(RT.inkFaint)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Color(hex: "#f4eee2")))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 12)
                        if contact.id != invited.last?.id {
                            Divider().overlay(RT.divider)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))

                ShareLink(item: shareText) {
                    Label("Send them the invite code", systemImage: "paperplane.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(accent))
                }
                .padding(.top, 14)
            }
        }
    }

    private func addContact() {
        let value = input.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        invited.append(InvitedContact(value: value))
        input = ""
    }

    // MARK: QR / code

    private var qrCode: some View {
        VStack(spacing: 16) {
            if let qr = RTQR.image(from: joinLink) {
                VStack(spacing: 8) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable().scaledToFit()
                        .frame(width: 200, height: 200)
                    Text("Scan to join instantly")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RT.inkMuted)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
            }

            VStack(spacing: 6) {
                Text("Invite code")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RT.inkMuted)
                Text(code)
                    .font(.system(size: 32, weight: .heavy, design: .monospaced))
                    .tracking(6)
                    .foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))

            HStack(spacing: 10) {
                ShareLink(item: joinURL) {
                    Label("Copy link", systemImage: "link")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.12)))
                }
                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 14).fill(accent))
                }
            }
        }
    }

    private func adminToggleRow(_ toggle: Binding<Bool>) -> some View {
        Toggle(isOn: toggle) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New members join as admins")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RT.ink)
                Text("Applied once push is enabled; until then promote via Manage members.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RT.inkMuted)
            }
        }
        .tint(accent)
        .onChange(of: toggle.wrappedValue) { _, v in onAdminToggleChange?(v) }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RT.cardBorder, lineWidth: 1))
    }
}

private struct InvitedContact: Identifiable {
    let id = UUID()
    let value: String

    var isEmail: Bool { value.contains("@") }
    var kindLabel: String { isEmail ? "Email invite" : "Text invite" }
    var initials: String {
        let base = isEmail ? value : value.filter { $0.isNumber }
        return String(base.prefix(1)).uppercased()
    }
}
