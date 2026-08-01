//
//  RTManageMembersView.swift
//  WhoZup
//
//  Admin-only member management: promote members to admin or remove admin
//  rights. A group always keeps at least one admin (enforced in the repository
//  and security rules).
//

import SwiftUI

struct RTManageMembersView: View {
    let groupId: String

    @Environment(GroupRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var memberToRemove: RTMember?

    private var group: RTGroup? { repository.group(id: groupId) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(group?.roster ?? []) { member in
                        HStack(spacing: 12) {
                            RTAvatar(initials: member.initials, color: member.displayAvatarColor, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                if member.isAdmin {
                                    Text("Admin")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(RTGroupType.accountability.accent)
                                }
                            }
                            Spacer()
                            // Explicit, always-visible actions. `.borderless` so each
                            // button gets its own tap target inside the List row.
                            VStack(alignment: .trailing, spacing: 6) {
                                roleButton(for: member)
                                // You can't remove yourself here; leaving is separate.
                                if !member.isYou {
                                    Button("Remove", role: .destructive) {
                                        memberToRemove = member
                                    }
                                    .font(.system(size: 13, weight: .bold))
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Admins can change the group and manage other members. A group always keeps at least one admin.")
                }
            }
            .navigationTitle("Manage members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                memberToRemove.map { "Remove \($0.displayName) from the group?" } ?? "",
                isPresented: Binding(
                    get: { memberToRemove != nil },
                    set: { if !$0 { memberToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let member = memberToRemove {
                    Button("Remove \(member.displayName)", role: .destructive) {
                        Task { await repository.removeMember(groupId: groupId, memberUid: member.uid) }
                        memberToRemove = nil
                    }
                }
                Button("Cancel", role: .cancel) { memberToRemove = nil }
            } message: {
                Text("They'll lose access to this group. They can rejoin with an invite.")
            }
        }
    }

    @ViewBuilder private func roleButton(for member: RTMember) -> some View {
        if member.isAdmin {
            Button("Remove admin", role: .destructive) {
                Task { await repository.removeAdmin(groupId: groupId, memberUid: member.uid) }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.borderless)
            .disabled((group?.adminUids.count ?? 0) <= 1)
        } else {
            Button("Make admin") {
                Task { await repository.promoteToAdmin(groupId: groupId, memberUid: member.uid) }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.borderless)
        }
    }
}
