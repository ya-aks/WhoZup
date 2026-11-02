//
//  RTAddMembersView.swift
//  WhoZup
//
//  Created by Antigravity on 01/08/26.
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

                    Text("Scan the QR code or share the link/code below to invite members.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(.top, 4)

                    qrCode.padding(.top, 20)

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
