//
//  PricingService.swift
//  DetailCRM
//
//  Catalog reads and server pricing for building jobs. Prices always come
//  from `price_services` (category price, else base price; membership
//  inclusions at 0 and the member discount suggested) — the app never
//  derives a price itself. `price_services` is manager+ only (technicians
//  get 42501), so only screens that edit lines call it.
//

import Foundation
import Supabase

enum PricingService {

    /// The shop's active, non-archived catalog with categories and add-on links.
    static func catalog(shopID: UUID) async throws -> JobCatalog {
        async let entriesTask = entries(shopID: shopID)
        async let categoriesTask = categories(shopID: shopID)
        async let linksTask = addonLinks(shopID: shopID)
        let entries = try await entriesTask
        let categories = try await categoriesTask
        let links = try await linksTask
        return JobCatalog(entries: entries, categories: categories, addonLinks: links)
    }

    private static func entries(shopID: UUID) async throws -> [JobCatalogEntry] {
        try await Supa.client
            .from("services")
            .select(JobCatalogEntry.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("active", value: true)
            .is("archived_at", value: nil)
            .order("sort", ascending: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    private static func categories(shopID: UUID) async throws -> [JobServiceCategory] {
        try await Supa.client
            .from("service_categories")
            .select("id,name,sort")
            .eq("shop_id", value: shopID.uuidString)
            .order("sort", ascending: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    private static func addonLinks(shopID: UUID) async throws -> [JobServiceAddonLink] {
        try await Supa.client
            .from("service_addons")
            .select("service_id,addon_id")
            .eq("shop_id", value: shopID.uuidString)
            .execute()
            .value
    }

    /// Prices `serviceIDs` for a customer's vehicle (category from the
    /// vehicle unless `vehicleCategoryID` is given), applying the
    /// customer's active memberships.
    static func price(
        shopID: UUID,
        customerID: UUID?,
        vehicleCategoryID: UUID?,
        serviceIDs: [UUID],
        vehicleID: UUID?
    ) async throws -> JobPricing {
        guard !serviceIDs.isEmpty else {
            throw AppError.invalidInput("Choose at least one service.")
        }
        let params = JobPriceServicesParams(
            shopID: shopID,
            customerID: customerID,
            vehicleCategoryID: vehicleCategoryID,
            serviceIDs: serviceIDs,
            vehicleID: vehicleID
        )
        return try await Supa.client
            .rpc("price_services", params: params)
            .execute()
            .value
    }
}

extension PricingService {

    /// Prices the whole catalog (in chunks of 100, the RPC's limit) for a
    /// customer's vehicle, so pickers can show each service's real price.
    static func priceCatalog(
        shopID: UUID,
        catalog: JobCatalog,
        customerID: UUID?,
        vehicleCategoryID: UUID?,
        vehicleID: UUID?
    ) async throws -> JobPricedCatalog {
        let ids = catalog.entries.map(\.id)
        guard !ids.isEmpty else { return .empty }
        var prices: [UUID: PricedService] = [:]
        var memberships: [JobPricingMembership] = []
        var suggested = 0
        var taxRate: Int?
        var start = 0
        while start < ids.count {
            let end = min(start + 100, ids.count)
            let chunk = Array(ids[start..<end])
            let pricing = try await price(
                shopID: shopID,
                customerID: customerID,
                vehicleCategoryID: vehicleCategoryID,
                serviceIDs: chunk,
                vehicleID: vehicleID
            )
            for line in pricing.lines {
                prices[line.serviceID] = line
            }
            if memberships.isEmpty {
                memberships = pricing.memberships
            }
            if pricing.suggestedDiscountKind == .percent {
                suggested = max(suggested, pricing.suggestedDiscountValue)
            }
            taxRate = taxRate ?? pricing.taxRateBps
            start = end
        }
        return JobPricedCatalog(
            prices: prices,
            memberships: memberships,
            suggestedDiscountBps: suggested,
            taxRateBps: taxRate
        )
    }
}

/// `p_shop`, `p_customer_id` (explicit null for a walk-in price) and
/// `p_service_ids` are always sent; the category and vehicle are omitted
/// when unknown (their SQL defaults are null — a shop without vehicle
/// categories prices at the base price).
// rpc: price_services
private struct JobPriceServicesParams: Encodable {
    let shopID: UUID
    let customerID: UUID?
    let vehicleCategoryID: UUID?
    let serviceIDs: [UUID]
    let vehicleID: UUID?

    enum CodingKeys: String, CodingKey {
        case shopID = "p_shop"
        case customerID = "p_customer_id"
        case vehicleCategoryID = "p_vehicle_category_id"
        case serviceIDs = "p_service_ids"
        case vehicleID = "p_vehicle_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shopID, forKey: .shopID)
        try container.encode(customerID, forKey: .customerID)
        try container.encodeIfPresent(vehicleCategoryID, forKey: .vehicleCategoryID)
        try container.encode(serviceIDs, forKey: .serviceIDs)
        try container.encodeIfPresent(vehicleID, forKey: .vehicleID)
    }
}
