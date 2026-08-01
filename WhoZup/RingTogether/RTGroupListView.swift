//
//  RTGroupListView.swift
//  WhoZup
//
//  A tab's group list (Accountability / Shared / Events), backed by the live
//  Firestore repository. Tapping a card pushes the matching detail screen;
//  the "+ New group" button and a "Join by code" action create/join real
//  Firestore groups.
//

import SwiftUI

struct RTGroupListView: View {
    let type: RTGroupType

    @Environment(GroupRepository.self) private var repository
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showHelp = false
    @State private var showFabMenu = false

    private var groups: [RTGroup] { repository.groups(of: type) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        RTEyebrow(type: type)
                        Spacer()
                        Button {
                            showHelp = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "questionmark.circle")
                                Text("How it works")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(type.accent)
                        }
                    }

                    Text(type.listTitle)
                        .font(.rtDisplay(28, .bold))
                        .foregroundStyle(RT.ink)
                        .padding(.top, 8)

                    Text(type.listSubtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                        .padding(.top, 4)

                    if type == .event {
                        RTFreeEventsBanner(usedCount: repository.eventsCreatedCount)
                            .padding(.top, 16)
                    }

                    VStack(spacing: 14) {
                        if groups.isEmpty {
                            RTEmptyState(type: type)
                                .padding(.top, 8)
                        }

                        ForEach(groups) { group in
                            NavigationLink {
                                destination(for: group)
                            } label: {
                                RTGroupCard(group: group)
                            }
                            .buttonStyle(RTPressStyle())
                        }
                    }
                    .padding(.top, 18)
                }
                .padding(20)
                .padding(.bottom, 110)
            }
            .background(RT.canvas)
            .scrollIndicators(.hidden)
            // A floating "＋" pinned above the tab bar. It hosts both ways to
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    if showFabMenu {
                        // Top option: "New group" (appears second with slight delay)
                        Button {
                            withAnimation { showFabMenu = false }
                            showCreate = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 14, weight: .bold))
                                Text("New group")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(RT.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).animation(.spring(response: 0.3, dampingFraction: 0.75).delay(0.06)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))
                        ))

                        // Bottom option: "Join by code" (appears first)
                        Button {
                            withAnimation { showFabMenu = false }
                            showJoin = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "number")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Join by code")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(RT.ink)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).animation(.spring(response: 0.3, dampingFraction: 0.75)),
                            removal: .opacity.animation(.easeIn(duration: 0.1))
                        ))
                    }

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            showFabMenu.toggle()
                        }
                    } label: {
                        Image(systemName: showFabMenu ? "xmark" : "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(Circle().fill(type.accent))
                            .shadow(color: type.accent.opacity(0.35), radius: 12, y: 6)
                            .rotationEffect(.degrees(showFabMenu ? 90 : 0))
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 74)
            }
        }
        .sheet(isPresented: $showCreate) {
            RTCreateGroupSheet(type: type)
        }
        .sheet(isPresented: $showJoin) {
            RTJoinGroupSheet()
        }
        .sheet(isPresented: $showHelp) {
            RTHowItWorksSheet(type: type)
        }
    }

    @ViewBuilder private func destination(for group: RTGroup) -> some View {
        if group.type == .event {
            RTEventDetailView(groupId: group.id)
        } else {
            RTGroupDetailView(groupId: group.id)
        }
    }
}

/// Subtle scale-on-press to match the design's `transform: scale(0.985)`.
struct RTPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Shown when a tab has no groups yet.
struct RTEmptyState: View {
    let type: RTGroupType

    private var message: String {
        switch type {
        case .accountability: return "No accountability groups yet. Create one and invite friends to keep each other on time."
        case .shared: return "No shared groups yet. Create one common wake-up for the whole crew."
        case .event: return "No events yet. Start one to send a one-tap “are you coming?” check."
        }
    }

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(RT.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
    }
}

/// The "N of 5 free events used" banner on the Events tab.
struct RTFreeEventsBanner: View {
    let usedCount: Int
    @StateObject private var eventPackStore = EventPackStore.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(min(usedCount, 5)) of 5 free events used")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: "#9a6410"))
                    Text("Only events you host count · never reset")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "#a9702a"))
                }
                Spacer()
                Button {
                    Task {
                        _ = await eventPackStore.purchaseEventPack()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if eventPackStore.isPurchasing {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else {
                            Text("+20 · $10")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(hex: "#d98c3a")))
                }
                .disabled(eventPackStore.isPurchasing)
            }

            if let error = eventPackStore.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(hex: "#fbeed6")))
    }
}
