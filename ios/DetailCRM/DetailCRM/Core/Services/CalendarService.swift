//
//  CalendarService.swift
//  DetailCRM
//
//  Staff calendar feed (`calendar_events`, 0007) and team colors
//  (`shop_team`). The server decides what each role sees: technicians get
//  other people's jobs as anonymous busy blocks.
//

import Foundation
import Supabase

enum CalendarService {

    /// The server caps one request at 93 days.
    static let maxRangeDays = 93

    private struct EventParams: Encodable {
        let p_shop_id: String
        let p_from: String
        let p_to: String
        let p_include_cancelled: Bool
    }

    /// Jobs and blocked times overlapping `[from, to)`, ordered by start.
    static func events(
        shopID: UUID,
        from: Date,
        to: Date,
        includeCancelled: Bool = false
    ) async throws -> [CalendarEvent] {
        guard to > from else {
            throw AppError.invalidInput("The calendar range is empty.")
        }
        let params = EventParams(
            p_shop_id: shopID.uuidString,
            p_from: Supa.iso(from),
            p_to: Supa.iso(to),
            p_include_cancelled: includeCancelled
        )
        let rows: [CalendarEvent] = try await Supa.client
            .rpc("calendar_events", params: params)
            .execute()
            .value
        return rows.sorted(by: CalendarService.startOrder)
    }

    /// Start, then end, then key — a stable order for lists and layout.
    static func startOrder(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
        if lhs.endsAt != rhs.endsAt { return lhs.endsAt < rhs.endsAt }
        return lhs.key < rhs.key
    }

    /// Active team members with their calendar colors (names/colors only for
    /// technicians).
    static func team(shopID: UUID) async throws -> [CalendarTeamMember] {
        let rows: [CalendarTeamMember] = try await Supa.client
            .rpc("shop_team", params: ["p_shop_id": shopID.uuidString])
            .execute()
            .value
        return rows.filter { $0.active }
    }
}
