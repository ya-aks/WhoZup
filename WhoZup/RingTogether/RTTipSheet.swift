//
//  RTTipSheet.swift
//  WhoZup
//
//  RingTogether-styled tip sheet. Presentation matches the design; purchases
//  route through the existing StoreKit-backed `TipStore` (issue #14). No
//  feature is gated behind tipping.
//

import SwiftUI

struct RTTipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tipStore = TipStore()
    @State private var purchasingTierID: String?

    /// Fallback display tiers matching the design when StoreKit products
    /// aren't loaded (e.g. no StoreKit config in the scheme).
    private let fallbackPrices = ["$3", "$5", "$10"]

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(RT.cardBorder).frame(width: 40, height: 5).padding(.top, 10)

            Text("♥")
                .font(.system(size: 34))
                .foregroundStyle(Color(hex: "#c07a7a"))
                .padding(.top, 18)

            Text("Leave a tip")
                .font(.rtDisplay(24, .bold))
                .foregroundStyle(RT.ink)
                .padding(.top, 10)

            Text("Completely optional — every feature stays free either way. Just a thank-you if whoZup helps.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RT.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            if showThankYou {
                VStack(spacing: 8) {
                    Text("Thank you so much! ❤️")
                        .font(.rtDisplay(20, .bold))
                        .foregroundStyle(RT.ink)
                    Text("Your support means the world to us.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RT.inkMuted)
                }
                .padding(.top, 28)
            } else {
                HStack(spacing: 12) {
                    ForEach(tipStore.tiers) { tier in
                        priceButton(label: tier.displayPrice, tier: tier)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
            }

            if let error = tipStore.loadError, !showThankYou {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(RT.dotLate)
                    .padding(.top, 10)
            }

            Button(showThankYou ? "Close" : "Maybe later") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RT.inkMuted)
                .padding(.top, 18)
                .padding(.bottom, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(RT.canvas)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.hidden)
        .task { await tipStore.loadProducts() }
    }

    @State private var showThankYou = false

    private func priceButton(label: String, tier: TipTier) -> some View {
        let isPurchasing = purchasingTierID == tier.id
        return Button {
            Task {
                purchasingTierID = tier.id
                await tipStore.purchase(tier)
                purchasingTierID = nil
                if case .success = tipStore.state(for: tier.id) {
                    withAnimation {
                        showThankYou = true
                    }
                }
            }
        } label: {
            Group {
                if isPurchasing {
                    ProgressView()
                } else {
                    Text(label)
                        .font(.rtDisplay(20, .bold))
                        .foregroundStyle(RT.ink)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 16).fill(RT.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RT.cardBorder, lineWidth: 1))
        }
        .buttonStyle(RTPressStyle())
        .disabled(purchasingTierID != nil)
    }
}
