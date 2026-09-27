//
//  VehicleService.swift
//  DetailCRM
//
//  A customer's vehicles and the shop's vehicle size classes (SPEC §4.1,
//  §4.2). Vehicles are soft-deleted via `archived_at`. Writes are
//  manager+ (RLS); technicians read vehicles on their assigned jobs.
//

import Foundation
import Supabase

enum VehicleService {

    /// Active vehicles of a customer, newest model year first.
    static func list(shopID: UUID, customerID: UUID) async throws -> [Vehicle] {
        try await Supa.client
            .from("vehicles")
            .select(Vehicle.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("customer_id", value: customerID.uuidString)
            .is("archived_at", value: nil)
            .order("year", ascending: false, nullsFirst: false)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// The shop's vehicle size classes in display order.
    static func categories(shopID: UUID) async throws -> [VehicleCategory] {
        try await Supa.client
            .from("vehicle_categories")
            .select(VehicleCategory.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .order("sort", ascending: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    static func create(shopID: UUID, customerID: UUID, draft: VehicleDraft) async throws -> Vehicle {
        if let problem = draft.validationError { throw AppError.invalidInput(problem) }
        var payload = draft
        payload.shopID = shopID
        payload.customerID = customerID
        let created: Vehicle = try await Supa.client
            .from("vehicles")
            .insert(payload, returning: .representation)
            .select(Vehicle.selectColumns)
            .single()
            .execute()
            .value
        return created
    }

    static func update(shopID: UUID, vehicleID: UUID, draft: VehicleDraft) async throws -> Vehicle {
        if let problem = draft.validationError { throw AppError.invalidInput(problem) }
        var payload = draft
        payload.shopID = nil
        payload.customerID = nil
        let rows: [Vehicle] = try await Supa.client
            .from("vehicles")
            .update(payload, returning: .representation)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: vehicleID.uuidString)
            .select(Vehicle.selectColumns)
            .execute()
            .value
        guard let updated = rows.first else {
            throw AppError.message("You don't have permission to edit this vehicle.")
        }
        return updated
    }

    /// Removes a vehicle from the customer's list (soft delete: jobs and
    /// history that reference it keep working).
    static func archive(shopID: UUID, vehicleID: UUID) async throws {
        let rows: [Vehicle] = try await Supa.client
            .from("vehicles")
            .update(VehicleArchivePatch(archivedAt: Supa.iso(Date())), returning: .representation)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: vehicleID.uuidString)
            .select(Vehicle.selectColumns)
            .execute()
            .value
        if rows.isEmpty {
            throw AppError.message("You don't have permission to remove this vehicle.")
        }
    }
}

// table: vehicles
private struct VehicleArchivePatch: Encodable {
    let archivedAt: String

    enum CodingKeys: String, CodingKey {
        case archivedAt = "archived_at"
    }
}
