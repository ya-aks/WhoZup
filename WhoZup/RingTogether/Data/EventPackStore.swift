//
//  EventPackStore.swift
//  WhoZup
//
//  Created by Antigravity on 01/08/26.
//
//  StoreKit 2 manager for purchasing Event Packs (20 additional event polls).
//

import Combine
import FirebaseAuth
import FirebaseFirestore
import Foundation
import StoreKit

@MainActor
final class EventPackStore: ObservableObject {
    static let shared = EventPackStore()

    static let eventPackProductID = "com.whozup.eventpack.20"
    /// Non-consumable one-time unlock for unlimited events (₹299 / $3.99,
    /// localized by the store).
    static let lifetimeProductID = "com.whozup.events.lifetime"

    /// Fallback price labels used only until StoreKit's own localized
    /// `displayPrice` loads. Rupees in India, dollars elsewhere.
    static var isIndia: Bool { Locale.current.region?.identifier == "IN" }
    static var eventPackFallbackPrice: String { isIndia ? "₹99" : "$6.99" }
    static var lifetimeFallbackPrice: String { isIndia ? "₹299" : "$3.99" }

    @Published private(set) var eventPackProduct: Product?
    @Published private(set) var lifetimeProduct: Product?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var errorMessage: String?

    /// Back-compat alias for existing call sites that referenced `.product`.
    var product: Product? { eventPackProduct }

    /// Long-lived listener for `Transaction.updates`. Held so it lives for the
    /// app's lifetime (and is cancellable in `deinit`).
    private var updatesListener: Task<Void, Never>?

    private init() {
        // Start listening for transaction updates BEFORE any purchase can run.
        // StoreKit delivers Ask-to-Buy approvals, interrupted purchases, and
        // purchases made on another device only through this stream — without
        // it a user can be charged while the entitlement is never granted.
        updatesListener = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task {
            await loadProducts()
            // Catch anything that completed while no listener was running
            // (app killed mid-purchase) and restore the lifetime unlock on a
            // fresh install.
            await reconcileTransactions()
        }
    }

    deinit {
        updatesListener?.cancel()
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(
                for: [Self.eventPackProductID, Self.lifetimeProductID]
            )
            self.eventPackProduct = products.first { $0.id == Self.eventPackProductID }
            self.lifetimeProduct = products.first { $0.id == Self.lifetimeProductID }
        } catch {
            print("Failed to load event products: \(error.localizedDescription)")
        }
    }

    func purchaseEventPack() async -> Bool {
        if eventPackProduct == nil { await loadProducts() }
        guard let product = eventPackProduct else {
            errorMessage = "Event pack is currently unavailable."
            return false
        }
        return await executePurchase(product: product)
    }

    func purchaseLifetime() async -> Bool {
        if lifetimeProduct == nil { await loadProducts() }
        guard let product = lifetimeProduct else {
            errorMessage = "Lifetime unlock is currently unavailable."
            return false
        }
        return await executePurchase(product: product)
    }

    /// Restores previously purchased non-consumables (the lifetime unlock).
    /// Consumables — event packs and tips — are used up and cannot be restored.
    /// Required on iOS: App Review expects a user-triggerable restore whenever
    /// an app sells a non-consumable. Returns true if the lifetime unlock was
    /// found and re-granted.
    @discardableResult
    func restorePurchases() async -> Bool {
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        do {
            // Prompts for the App Store account and refreshes entitlements from
            // Apple, so a purchase made on another device/install is picked up.
            try await AppStore.sync()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        var restoredLifetime = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.lifetimeProductID {
                await grant(for: transaction.productID)
                restoredLifetime = true
            }
        }

        if !restoredLifetime {
            errorMessage = "No previous purchases to restore."
        }
        return restoredLifetime
    }

    private func executePurchase(product: Product) async -> Bool {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await grant(for: transaction.productID)
                    await transaction.finish()
                    return true
                case .unverified:
                    errorMessage = "Transaction verification failed."
                    return false
                }
            case .userCancelled:
                return false
            case .pending:
                errorMessage = "Purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Verifies a transaction from any source (direct purchase, the updates
    /// stream, or launch reconciliation), grants its entitlement, and finishes
    /// it so StoreKit stops redelivering it.
    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await grant(for: transaction.productID)
        await transaction.finish()
    }

    /// On launch, drain transactions that completed while no listener was
    /// running (e.g. app terminated mid-purchase) and re-grant the lifetime
    /// unlock on a new install/device. Idempotent: event-pack grants are
    /// finished so they aren't redelivered; lifetime is a flag, safe to re-set.
    private func reconcileTransactions() async {
        for await result in Transaction.unfinished {
            await handle(result)
        }
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.lifetimeProductID {
                await grant(for: transaction.productID)
            }
        }
    }

    private func grant(for productID: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Firestore.firestore().collection("usage").document(uid)
        let data: [String: Any]
        switch productID {
        case Self.lifetimeProductID:
            data = ["eventsLifetime": true]
        case Self.eventPackProductID:
            data = ["eventPackBalance": FieldValue.increment(Int64(20))]
        default:
            // Tips and any unrecognized product carry no entitlement — the
            // listener still finishes them, but there is nothing to grant.
            return
        }
        do {
            try await ref.setData(data, merge: true)
        } catch {
            print("Failed to update event entitlement in Firestore: \(error.localizedDescription)")
        }
    }
}
