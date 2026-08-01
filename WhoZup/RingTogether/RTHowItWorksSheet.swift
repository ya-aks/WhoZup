//
//  RTHowItWorksSheet.swift
//  WhoZup
//
//  The "How it works" explainer. Each group tab shows a help pill that opens
//  this for its own feature; the More tab embeds the same `RTFeatureExplainer`
//  blocks inline for all three. Joining a group moved onto the ＋ menu, so the
//  shared join note points people there.
//

import SwiftUI

struct RTHowItWorksSheet: View {
    /// The single feature to explain; `nil` shows all three.
    let type: RTGroupType?

    @Environment(\.dismiss) private var dismiss

    private var typesToShow: [RTGroupType] {
        if let type { return [type] }
        return [.accountability, .shared, .event]
    }

    var body: some View {
        NavigationStack {
            Group {
                if type == nil {
                    carousel
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(typesToShow) { RTFeatureExplainer(type: $0) }
                            RTJoinNote()
                        }
                        .padding(20)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(RT.canvas)
            .navigationTitle(type == nil ? "How WhoZup works" : "How it works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The all-three variant (from the More tab) is a swipeable carousel — one
    /// feature per page with dots — rather than a long scroll.
    private var carousel: some View {
        VStack(spacing: 0) {
            TabView {
                ForEach(typesToShow) { t in
                    ScrollView {
                        RTFeatureExplainer(type: t).padding(20)
                    }
                    .scrollIndicators(.hidden)
                    .tag(t)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            RTJoinNote()
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }
}

/// One feature's icon + title + casual explanation, tinted to its accent.
struct RTFeatureExplainer: View {
    let type: RTGroupType

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(type.iconAsset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(type.accent)
                Text(type.helpTitle)
                    .font(.rtDisplay(18, .bold))
                    .foregroundStyle(RT.ink)
            }
            Text(type.helpBody)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RT.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20).fill(RT.card))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(RT.cardBorder, lineWidth: 1))
    }
}

/// The shared "how to join" footer, pointing at the ＋ menu that now hosts it.
struct RTJoinNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(RT.inkMuted)
            Text("To join a group, tap the ＋ button and choose “Join by code”, then paste the invite a friend shared.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RT.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
    }
}
