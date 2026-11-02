//
//  TipStore.swift
//  WhoZup
//
//  Created by akshay yadav on 25/06/26.
//
//  Optional tip/donation flow (GitHub issue #14).
//
//  Entirely client-side via StoreKit 2 consumable in-app purchases.
//  No feature in the app is gated behind this — it is a purely optional
//  "Support WhoZup" entry point reachable from the main screen.
//
//  IMPORTANT: The product identifiers below must be created as
//  Consumable In-App Purchases in App Store Connect before real
//  purchases will work. For local development/testing, add a
//  StoreKit configuration file (Tips.storekit) with matching
//  product identifiers and run with that configuration enabled
//  in the Xcode scheme (Product > Scheme > Edit Scheme > Run > Options
//  > StoreKit Configuration).
//

import Foundation
import StoreKit

/// A tip tier the user can purchase. Value type used purely for display;
/// it is derived from a StoreKit `Product` but carries no StoreKit types
/// so views and tests don't need to depend on StoreKit.
struct TipTier: Identifiable, Hashable {
    let id: String
    let displayName: String
    let displayPrice: String
    /// Raw price used only for sorting low -> high.
    let priceValue: Decimal

    init(id: String, displayName: String, displayPrice: String, priceValue: Decimal) {
        self.id = id
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.priceValue = priceValue
    }
}

extension TipTier {
    /// Builds a display model from a live StoreKit product.
    init(product: Product) {
        self.id = product.id
        self.displayName = product.displayName.isEmpty ? product.id : product.displayName
        self.displayPrice = product.displayPrice
        self.priceValue = product.price
    }
}

/// Result of attempting to purchase a tip.
enum TipPurchaseOutcome: Equatable {
    case success
    case userCancelled
    case pending
    case failed(String)
}

/// Per-tier purchase state, used to drive the UI.
enum TipPurchaseState: Equatable {
    case idle
    case purchasing
    case success
    case failed(String)
}

/// Narrow seam around StoreKit so `TipStore` can be unit tested without
/// hitting real StoreKit APIs. The production implementation talks to
/// `Product.purchase()`; a fake implementation can be substituted in tests.
protocol TipPurchasing {
    func fetchProducts(for identifiers: [String]) async throws -> [TipTier]
    func purchase(productID: String) async throws -> TipPurchaseOutcome
}

/// Production implementation backed by StoreKit 2.
struct StoreKitTipPurchaser: TipPurchasing {
    func fetchProducts(for identifiers: [String]) async throws -> [TipTier] {
        let products = try await Product.products(for: identifiers)
        return products.map(TipTier.init(product:))
    }

    func purchase(productID: String) async throws -> TipPurchaseOutcome {
        let products = try await Product.products(for: [productID])
        guard let product = products.first else {
            return .failed("Product not found")
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                // Consumables: finish immediately, there is no entitlement to track.
                await transaction.finish()
                return .success
            case .unverified:
                return .failed("Could not verify transaction")
            }
        case .userCancelled:
            return .userCancelled
        case .pending:
            return .pending
        @unknown default:
            return .failed("Unknown purchase result")
        }
    }
}

/// Deep module: hides all StoreKit complexity behind `loadProducts()` and
/// `purchase(_:)`. Owns no app-wide singleton state — instantiate and inject
/// at the call site (e.g. `@State private var tipStore = TipStore()` in a view).
@MainActor
@Observable
final class TipStore {
    /// Product identifiers for the tip tiers offered.
    /// These must exist as Consumable IAPs in App Store Connect, and in any
    /// local .storekit configuration used for testing.
    static let productIdentifiers = [
        "com.whozup.tip.small",
        "com.whozup.tip.medium",
        "com.whozup.tip.large",
    ]

    private(set) var tiers: [TipTier] = []
    private(set) var purchaseStates: [String: TipPurchaseState] = [:]
    private(set) var isLoadingProducts = false
    private(set) var loadError: String?
    /// True when live StoreKit products couldn't be fetched (offline, or the IAPs
    /// aren't configured/approved yet). The UI shows an "unavailable" message
    /// rather than fake, un-purchasable tiers — App Store review rejects IAP
    /// buttons that look functional but aren't.
    private(set) var productsUnavailable = false

    private let purchaser: TipPurchasing

    init(purchaser: TipPurchasing = StoreKitTipPurchaser()) {
        self.purchaser = purchaser
    }

    func state(for tierID: String) -> TipPurchaseState {
        purchaseStates[tierID] ?? .idle
    }

    /// Fetches the available tip tiers, sorted from cheapest to most expensive.
    func loadProducts() async {
        isLoadingProducts = true
        loadError = nil
        defer { isLoadingProducts = false }

        do {
            let fetched = try await purchaser.fetchProducts(for: Self.productIdentifiers)
            if fetched.isEmpty {
                // Products aren't available (not configured/approved, or offline).
                // Show nothing purchasable rather than fabricated tiers.
                tiers = []
                productsUnavailable = true
            } else {
                tiers = fetched.sorted { $0.priceValue < $1.priceValue }
                productsUnavailable = false
            }
        } catch {
            loadError = error.localizedDescription
            tiers = []
            productsUnavailable = true
        }
    }

    /// True when the device's App Store region is India. Used only to pick the
    /// fallback tip currency below — the live StoreKit path localizes prices on
    /// its own from the buyer's storefront, so it needs no region check.
    static var isIndiaRegion: Bool {
        Locale.current.region?.identifier == "IN"
    }

    /// Shown when live products can't be fetched (offline, or IAPs not yet
    /// configured). Rupee tiers in India, dollar tiers elsewhere.
    static var defaultFallbackTiers: [TipTier] {
        if isIndiaRegion {
            return [
                TipTier(id: "com.whozup.tip.small", displayName: "Small Tip", displayPrice: "₹29", priceValue: 29),
                TipTier(id: "com.whozup.tip.medium", displayName: "Medium Tip", displayPrice: "₹99", priceValue: 99),
                TipTier(id: "com.whozup.tip.large", displayName: "Large Tip", displayPrice: "₹149", priceValue: 149)
            ]
        }
        return [
            TipTier(id: "com.whozup.tip.small", displayName: "Small Tip", displayPrice: "$0.99", priceValue: 0.99),
            TipTier(id: "com.whozup.tip.medium", displayName: "Medium Tip", displayPrice: "$3.99", priceValue: 3.99),
            TipTier(id: "com.whozup.tip.large", displayName: "Large Tip", displayPrice: "$6.99", priceValue: 6.99)
        ]
    }

    /// Initiates a purchase for the given tier and updates `purchaseStates`.
    func purchase(_ tier: TipTier) async {
        purchaseStates[tier.id] = .purchasing

        do {
            let outcome = try await purchaser.purchase(productID: tier.id)
            switch outcome {
            case .success:
                purchaseStates[tier.id] = .success
            case .userCancelled:
                purchaseStates[tier.id] = .idle
            case .pending:
                purchaseStates[tier.id] = .idle
            case .failed(let message):
                purchaseStates[tier.id] = .failed(message)
            }
        } catch {
            purchaseStates[tier.id] = .failed(error.localizedDescription)
        }
    }

    /// Resets a tier's purchase state back to idle (e.g. to dismiss an error/success banner).
    func resetState(for tierID: String) {
        purchaseStates[tierID] = .idle
    }
}
