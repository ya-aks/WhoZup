//
//  TipStoreTests.swift
//  WhoZupTests
//
//  Created by akshay yadav on 25/06/26.
//
//  Unit tests for the tip/donation flow (GitHub issue #14) that don't
//  require live StoreKit transactions: product mapping/sorting and the
//  purchase state machine, exercised via a fake TipPurchasing.
//
//  NOT covered here (needs simulator + Tips.storekit / manual QA):
//  - Real StoreKit product fetch via Product.products(for:)
//  - Real Product.purchase() flow and VerificationResult handling
//  - Transaction.finish() behavior for consumables

import XCTest
@testable import WhoZup

private struct FakeTipPurchasing: TipPurchasing {
    var productsResult: Result<[TipTier], Error> = .success([])
    var purchaseResult: Result<TipPurchaseOutcome, Error> = .success(.success)

    func fetchProducts(for identifiers: [String]) async throws -> [TipTier] {
        try productsResult.get()
    }

    func purchase(productID: String) async throws -> TipPurchaseOutcome {
        try purchaseResult.get()
    }
}

private struct StubError: Error, LocalizedError {
    var errorDescription: String? { "stub failure" }
}

@MainActor
final class TipStoreTests: XCTestCase {

    func testLoadProductsSortsTiersByPriceAscending() async {
        let unsorted = [
            TipTier(id: "com.whozup.tip.large", displayName: "Large Tip", displayPrice: "$9.99", priceValue: 9.99),
            TipTier(id: "com.whozup.tip.small", displayName: "Small Tip", displayPrice: "$1.99", priceValue: 1.99),
            TipTier(id: "com.whozup.tip.medium", displayName: "Medium Tip", displayPrice: "$4.99", priceValue: 4.99),
        ]
        let fake = FakeTipPurchasing(productsResult: .success(unsorted))
        let store = TipStore(purchaser: fake)

        await store.loadProducts()

        XCTAssertEqual(store.tiers.map(\.id), [
            "com.whozup.tip.small",
            "com.whozup.tip.medium",
            "com.whozup.tip.large",
        ])
        XCTAssertNil(store.loadError)
        XCTAssertFalse(store.isLoadingProducts)
    }

    func testLoadProductsSurfacesErrorMessage() async {
        let fake = FakeTipPurchasing(productsResult: .failure(StubError()))
        let store = TipStore(purchaser: fake)

        await store.loadProducts()

        XCTAssertTrue(store.tiers.isEmpty)
        XCTAssertEqual(store.loadError, "stub failure")
    }

    func testPurchaseSuccessSetsStateToSuccess() async {
        let fake = FakeTipPurchasing(purchaseResult: .success(.success))
        let store = TipStore(purchaser: fake)
        let tier = TipTier(id: "com.whozup.tip.small", displayName: "Small Tip", displayPrice: "$1.99", priceValue: 1.99)

        XCTAssertEqual(store.state(for: tier.id), .idle)

        await store.purchase(tier)

        XCTAssertEqual(store.state(for: tier.id), .success)
    }

    func testPurchaseUserCancelledReturnsToIdle() async {
        let fake = FakeTipPurchasing(purchaseResult: .success(.userCancelled))
        let store = TipStore(purchaser: fake)
        let tier = TipTier(id: "com.whozup.tip.medium", displayName: "Medium Tip", displayPrice: "$4.99", priceValue: 4.99)

        await store.purchase(tier)

        XCTAssertEqual(store.state(for: tier.id), .idle)
    }

    func testPurchasePendingReturnsToIdle() async {
        let fake = FakeTipPurchasing(purchaseResult: .success(.pending))
        let store = TipStore(purchaser: fake)
        let tier = TipTier(id: "com.whozup.tip.large", displayName: "Large Tip", displayPrice: "$9.99", priceValue: 9.99)

        await store.purchase(tier)

        XCTAssertEqual(store.state(for: tier.id), .idle)
    }

    func testPurchaseFailureOutcomeSetsFailedStateWithMessage() async {
        let fake = FakeTipPurchasing(purchaseResult: .success(.failed("network down")))
        let store = TipStore(purchaser: fake)
        let tier = TipTier(id: "com.whozup.tip.small", displayName: "Small Tip", displayPrice: "$1.99", priceValue: 1.99)

        await store.purchase(tier)

        XCTAssertEqual(store.state(for: tier.id), .failed("network down"))
    }

    func testPurchaseThrownErrorSetsFailedStateWithLocalizedMessage() async {
        let fake = FakeTipPurchasing(purchaseResult: .failure(StubError()))
        let store = TipStore(purchaser: fake)
        let tier = TipTier(id: "com.whozup.tip.small", displayName: "Small Tip", displayPrice: "$1.99", priceValue: 1.99)

        await store.purchase(tier)

        XCTAssertEqual(store.state(for: tier.id), .failed("stub failure"))
    }

    func testResetStateReturnsTierToIdle() async {
        let fake = FakeTipPurchasing(purchaseResult: .success(.success))
        let store = TipStore(purchaser: fake)
        let tier = TipTier(id: "com.whozup.tip.small", displayName: "Small Tip", displayPrice: "$1.99", priceValue: 1.99)

        await store.purchase(tier)
        XCTAssertEqual(store.state(for: tier.id), .success)

        store.resetState(for: tier.id)
        XCTAssertEqual(store.state(for: tier.id), .idle)
    }

    func testDefaultProductIdentifiersAreConsumableTipTiers() {
        XCTAssertEqual(TipStore.productIdentifiers, [
            "com.whozup.tip.small",
            "com.whozup.tip.medium",
            "com.whozup.tip.large",
        ])
    }
}
