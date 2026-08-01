//
//  TipView.swift
//  WhoZup
//
//  Created by akshay yadav on 25/06/26.
//
//  Optional "Support WhoZup" tip/donation screen (GitHub issue #14).
//  Purely discoverable from a settings-style entry point — no feature
//  in the app requires visiting or using this screen.
//

import SwiftUI

struct TipView: View {
    @State private var tipStore: TipStore

    @MainActor
    init(tipStore: TipStore? = nil) {
        _tipStore = State(initialValue: tipStore ?? TipStore())
    }

    var body: some View {
        List {
            Section {
                Text("WhoZup is free to use. If you'd like to support development, you can leave an optional one-time tip below. This never unlocks or gates any feature.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Tip Jar") {
                if tipStore.isLoadingProducts {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let loadError = tipStore.loadError {
                    Text("Couldn't load tip options: \(loadError)")
                        .foregroundStyle(.secondary)
                } else if tipStore.tiers.isEmpty {
                    Text("Tip options are unavailable right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tipStore.tiers) { tier in
                        TipTierRow(tier: tier, state: tipStore.state(for: tier.id)) {
                            await tipStore.purchase(tier)
                        }
                    }
                }
            }
        }
        .navigationTitle("Support WhoZup")
        .task {
            if tipStore.tiers.isEmpty {
                await tipStore.loadProducts()
            }
        }
    }
}

private struct TipTierRow: View {
    let tier: TipTier
    let state: TipPurchaseState
    let onTip: () async -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(tier.displayName)
                    .font(.body)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if case .success = state {
                    Text("Thank you!")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            Button {
                Task { await onTip() }
            } label: {
                switch state {
                case .purchasing:
                    ProgressView()
                case .success:
                    Label(tier.displayPrice, systemImage: "checkmark.circle.fill")
                default:
                    Text(tier.displayPrice)
                }
            }
            .buttonStyle(.bordered)
            .disabled(state == .purchasing)
        }
    }
}

#Preview {
    NavigationStack {
        TipView()
    }
}
