//
//  CatalogService.swift
//  DetailCRM
//
//  Reads the shop's catalog (every member) and the simple edits managers
//  make on the phone: a service's name / duration / active / online
//  bookable switches and its prices per vehicle category. Packages,
//  add-on links, new services and checklists are edited on the web.
//

import Foundation
import Supabase

enum CatalogService {

    /// Categories, items, prices, vehicle categories and checklist
    /// templates of the shop, loaded in parallel.
    static func snapshot(shopID: UUID) async throws -> CatalogSnapshot {
        async let categoryRows = Self.categories(shopID: shopID)
        async let itemRows = Self.items(shopID: shopID)
        async let priceRows = Self.prices(shopID: shopID)
        async let vehicleCategoryRows = Self.vehicleCategories(shopID: shopID)
        async let checklistRows = Self.checklistTemplates(shopID: shopID)
        return try await CatalogSnapshot(
            categories: categoryRows,
            items: itemRows,
            prices: priceRows,
            vehicleCategories: vehicleCategoryRows,
            checklists: checklistRows
        )
    }

    static func categories(shopID: UUID) async throws -> [ServiceCategory] {
        try await Supa.client
            .from("service_categories")
            .select(ServiceCategory.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .order("sort", ascending: true)
            .execute()
            .value
    }

    /// Every service row (archived ones are filtered by the caller).
    static func items(shopID: UUID) async throws -> [CatalogItem] {
        try await Supa.client
            .from("services")
            .select(CatalogItem.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .order("sort", ascending: true)
            .limit(2000)
            .execute()
            .value
    }

    static func prices(shopID: UUID) async throws -> [ServicePrice] {
        try await Supa.client
            .from("service_prices")
            .select(ServicePrice.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .limit(10000)
            .execute()
            .value
    }

    static func vehicleCategories(shopID: UUID) async throws -> [CatalogVehicleCategory] {
        try await Supa.client
            .from("vehicle_categories")
            .select(CatalogVehicleCategory.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .order("sort", ascending: true)
            .execute()
            .value
    }

    static func checklistTemplates(shopID: UUID) async throws -> [ChecklistTemplate] {
        try await Supa.client
            .from("checklist_templates")
            .select(ChecklistTemplate.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .order("name", ascending: true)
            .execute()
            .value
    }

    // MARK: - Edits (managers+; RLS enforces)

    /// Saves name / duration / active / online bookable.
    static func updateItem(shopID: UUID, itemID: UUID, update: CatalogItemUpdate) async throws -> CatalogItem {
        let rows: [CatalogItem] = try await Supa.client
            .from("services")
            .update(update, returning: .representation)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: itemID.uuidString)
            .select(CatalogItem.selectColumns)
            .execute()
            .value
        guard let row = rows.first else {
            throw AppError.message("That service couldn't be saved. It may have been removed, or you don't have permission.")
        }
        return row
    }

    /// Applies the price editor's changes one row at a time (deletes
    /// first, then updates, then inserts). Stops at the first failure;
    /// the caller reloads so the screen shows what was saved.
    static func applyPriceChanges(shopID: UUID, serviceID: UUID, changes: [CatalogPriceChange]) async throws {
        var deletes: [UUID] = []
        var updates: [(UUID, Int)] = []
        var inserts: [(UUID?, Int)] = []
        for change in changes {
            switch change {
            case .delete(let priceID):
                deletes.append(priceID)
            case .update(let priceID, let cents):
                updates.append((priceID, cents))
            case .insert(let categoryID, let cents):
                inserts.append((categoryID, cents))
            }
        }
        for priceID in deletes {
            try await Supa.client
                .from("service_prices")
                .delete()
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: priceID.uuidString)
                .execute()
        }
        for (priceID, cents) in updates {
            let rows: [ServicePrice] = try await Supa.client
                .from("service_prices")
                .update(ServicePriceUpdate(priceCents: cents), returning: .representation)
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: priceID.uuidString)
                .select(ServicePrice.selectColumns)
                .execute()
                .value
            if rows.isEmpty {
                throw AppError.message("A price couldn't be saved. You may not have permission to edit prices.")
            }
        }
        for (categoryID, cents) in inserts {
            let payload = ServicePriceInsert(shopID: shopID, serviceID: serviceID, vehicleCategoryID: categoryID, priceCents: cents)
            try await Supa.client
                .from("service_prices")
                .insert(payload, returning: .minimal)
                .execute()
        }
    }

    // MARK: - Service follow-ups (P-4)

    /// The maintenance follow-ups of one service (managers+; others get an
    /// empty list from RLS), in the shop's order.
    static func serviceFollowups(shopID: UUID, serviceID: UUID) async throws -> [OpsServiceFollowup] {
        try await Supa.client
            .from("service_followups")
            .select(OpsServiceFollowup.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("service_id", value: serviceID.uuidString)
            .order("sort", ascending: true)
            .order("offset_days", ascending: true)
            .execute()
            .value
    }
}
