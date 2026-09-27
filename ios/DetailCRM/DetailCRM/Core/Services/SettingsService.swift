//
//  SettingsService.swift
//  DetailCRM
//
//  Shop settings subset (SPEC §3: managers+ read, owners/admins write —
//  enforced by RLS on shops / booking_settings / business_hours) plus the
//  signed-in user's own profile and membership name. After changing
//  `shops` the caller refreshes AppState (`refreshCurrentShop()`).
//

import Foundation
import Supabase

enum SettingsService {

    // MARK: - Shop

    /// Fresh copy of the shop row (the settings screens edit from this,
    /// not from the possibly stale membership copy).
    static func shop(shopID: UUID) async throws -> Shop {
        let rows: [Shop] = try await Supa.client
            .from("shops")
            .select(Shop.selectColumns)
            .eq("id", value: shopID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let shop = rows.first else { throw AppError.notFound("The shop") }
        return shop
    }

    static func updateProfile(shopID: UUID, update: ShopSettingsProfileUpdate) async throws -> Shop {
        try await updateShop(shopID: shopID, payload: update)
    }

    static func updateTaxRate(shopID: UUID, basisPoints: Int) async throws -> Shop {
        try await updateShop(shopID: shopID, payload: ShopSettingsTaxUpdate(taxRateBps: basisPoints))
    }

    static func updateTechsCanCollect(shopID: UUID, allowed: Bool) async throws -> Shop {
        try await updateShop(shopID: shopID, payload: ShopSettingsCollectUpdate(techsCanCollectPayments: allowed))
    }

    private static func updateShop<Payload: Encodable & Sendable>(shopID: UUID, payload: Payload) async throws -> Shop {
        let rows: [Shop] = try await Supa.client
            .from("shops")
            .update(payload, returning: .representation)
            .eq("id", value: shopID.uuidString)
            .select(Shop.selectColumns)
            .execute()
            .value
        guard let shop = rows.first else {
            throw AppError.message("Only owners and admins can change shop settings.")
        }
        return shop
    }

    // MARK: - Booking settings

    static func booking(shopID: UUID) async throws -> ShopSettingsBooking? {
        let rows: [ShopSettingsBooking] = try await Supa.client
            .from("booking_settings")
            .select(ShopSettingsBooking.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Saves only the switch that changed (the other column is left as the
    /// server has it, so two quick taps can't undo each other).
    static func updateBooking(shopID: UUID, enabled: Bool? = nil, autoConfirm: Bool? = nil) async throws -> ShopSettingsBooking {
        let payload = ShopSettingsBookingUpdate(enabled: enabled, autoConfirm: autoConfirm)
        guard !payload.isEmpty else {
            throw AppError.invalidInput("Nothing to save.")
        }
        let rows: [ShopSettingsBooking] = try await Supa.client
            .from("booking_settings")
            .update(payload, returning: .representation)
            .eq("shop_id", value: shopID.uuidString)
            .select(ShopSettingsBooking.selectColumns)
            .execute()
            .value
        guard let row = rows.first else {
            throw AppError.message("Only owners and admins can change booking settings.")
        }
        return row
    }

    // MARK: - Business hours

    static func hours(shopID: UUID) async throws -> [BusinessHour] {
        try await Supa.client
            .from("business_hours")
            .select(BusinessHour.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .order("weekday", ascending: true)
            .order("opens_at", ascending: true)
            .execute()
            .value
    }

    static func addHour(_ draft: BusinessHourDraft) async throws {
        do {
            try await Supa.client
                .from("business_hours")
                .insert(draft, returning: .minimal)
                .execute()
        } catch {
            throw friendlyHoursError(error)
        }
    }

    static func updateHour(shopID: UUID, hourID: UUID, draft: BusinessHourDraft) async throws {
        do {
            let rows: [BusinessHour] = try await Supa.client
                .from("business_hours")
                .update(draft, returning: .representation)
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: hourID.uuidString)
                .select(BusinessHour.selectColumns)
                .execute()
                .value
            if rows.isEmpty {
                throw AppError.message("Only owners and admins can change business hours.")
            }
        } catch {
            throw friendlyHoursError(error)
        }
    }

    static func deleteHour(shopID: UUID, hourID: UUID) async throws {
        try await Supa.client
            .from("business_hours")
            .delete()
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: hourID.uuidString)
            .execute()
    }

    private static func friendlyHoursError(_ error: Error) -> Error {
        if let postgrest = error as? PostgrestError, postgrest.code == "23P01" {
            return AppError.message("These hours overlap another opening on the same day.")
        }
        return error
    }

    // MARK: - Stripe (read only; owners/admins can read the row)

    static func stripeAccount(shopID: UUID) async throws -> ShopSettingsStripeAccount? {
        let rows: [ShopSettingsStripeAccount] = try await Supa.client
            .from("shop_stripe_accounts")
            .select(ShopSettingsStripeAccount.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    // MARK: - Account (the signed-in user)

    static func updateMyProfile(fullName: String?, phone: String?) async throws {
        let userID = try await Supa.currentUserID()
        try await Supa.client
            .from("profiles")
            .update(ShopSettingsAccountUpdate(fullName: fullName, phone: phone), returning: .minimal)
            .eq("id", value: userID.uuidString)
            .execute()
    }

    static func updateMyDisplayName(shopID: UUID, memberID: UUID, displayName: String) async throws {
        try await Supa.client
            .from("shop_members")
            .update(ShopSettingsMemberNameUpdate(displayName: displayName), returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: memberID.uuidString)
            .execute()
    }
}
