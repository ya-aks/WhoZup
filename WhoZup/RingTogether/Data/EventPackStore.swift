//
//  EventPackStore.swift
//  WhoZup
//
//  Created by Antigravity on 01/08/26.
//
//  StoreKit 2 manager for purchasing Event Packs (20 additional event polls for $10).
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

    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    @Published private(set) var errorMessage: String?

    private init() {
        Task {
            await loadProduct()
        }
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.eventPackProductID])
            self.product = products.first
        } catch {
            print("Failed to load event pack product: \(error.localizedDescription)")
        }
    }

    func purchaseEventPack() async -> Bool {
        guard let product = self.product else {
            await loadProduct()
            guard let product = self.product else {
                errorMessage = "Event pack product is currently unavailable."
                return false
            }
            return await executePurchase(product: product)
        }
        return await executePurchase(product: product)
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
                    await transaction.finish()
                    await grantEventPackQuota(count: 20)
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

    private func grantEventPackQuota(count: Int) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Firestore.firestore().collection("usage").document(uid)
        do {
            try await ref.setData([
                "eventPackBalance": FieldValue.increment(Int64(count))
            ], merge: true)
        } catch {
            print("Failed to update event pack balance in Firestore: \(error.localizedDescription)")
        }
    }
}
