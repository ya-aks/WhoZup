//
//  RTFeedbackSheet.swift
//  WhoZup
//
//  More → Send feedback. Saves to `feedbacks/{id}` with who sent it (uid,
//  name, phone/email) and where from (platform, app version, device), so we
//  can read it in the Firebase console and follow up. Same shape as Android's
//  `FeedbackSheet`; see docs/data-model.md. Writing is queued, not awaited:
//  sent when tapped, synced when online.
//

import FirebaseAuth
import FirebaseFirestore
import SwiftUI
import UIKit

struct RTFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(GroupRepository.self) private var repository
    @State private var category = "idea"
    @State private var message = ""
    @State private var sent = false
    @FocusState private var focused: Bool

    private static let categories = [("idea", "Idea"), ("problem", "Something's wrong"), ("other", "Other")]
    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RT.inkMuted)
                Spacer()
            }
            if sent {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44)).foregroundStyle(RT.dotOnTime)
                    Text("Thanks! We read every one.")
                        .font(.rtDisplay(20, .bold)).foregroundStyle(RT.ink)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Text("Send feedback").font(.rtDisplay(26, .bold)).foregroundStyle(RT.ink)
                Text("Tell us what to fix or build next. We'll see your name so we can reply.")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(RT.inkMuted)
                HStack(spacing: 8) {
                    ForEach(Self.categories, id: \.0) { id, label in
                        let on = category == id
                        Button { category = id } label: {
                            Text(label)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(on ? .white : RT.inkSecondary)
                                .padding(.horizontal, 14).frame(minHeight: 38)
                                .background(Capsule().fill(on ? RT.ink : RT.card))
                                .overlay(Capsule().stroke(RT.cardBorder, lineWidth: on ? 0 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                TextEditor(text: $message)
                    .focused($focused)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 160)
                    .background(RoundedRectangle(cornerRadius: 14).fill(RT.card))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(RT.cardBorder, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text("What's on your mind?")
                                .font(.system(size: 16)).foregroundStyle(RT.inkFaint)
                                .padding(.horizontal, 15).padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }
                Button {
                    Self.send(category: category, message: String(trimmed.prefix(4000)), name: repository.myDisplayName)
                    RTAnalytics.feedbackSent(category: category)
                    focused = false
                    withAnimation { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { dismiss() }
                } label: {
                    Text("Send")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(RoundedRectangle(cornerRadius: 16).fill(trimmed.isEmpty ? RT.inkFaint : RT.ink))
                }
                .buttonStyle(RTPressStyle())
                .disabled(trimmed.isEmpty)
                Spacer()
            }
        }
        .padding(20)
        .background(RT.canvas)
        .onAppear { focused = true }
    }

    /// One `feedbacks` doc. Fields must match firestore.rules and Android.
    static func send(category: String, message: String, name: String) {
        guard let user = Auth.auth().currentUser else { return }
        let info = Bundle.main.infoDictionary
        var data: [String: Any] = [
            "uid": user.uid,
            "name": name,
            "category": category,
            "message": message,
            "platform": "ios",
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
            "build": info?["CFBundleVersion"] as? String ?? "",
            "osVersion": UIDevice.current.systemVersion,
            "device": deviceModel(),
            "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier,
            "status": "new",
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let phone = user.phoneNumber { data["phone"] = phone }
        if let email = user.email { data["email"] = email }
        Firestore.firestore().collection("feedbacks").addDocument(data: data) { _ in }
    }

    /// "iPhone17,1" etc.
    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
