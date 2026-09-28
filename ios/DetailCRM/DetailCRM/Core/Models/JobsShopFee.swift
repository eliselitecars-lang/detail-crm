//
//  JobsShopFee.swift
//  DetailCRM
//
//  Preset fees (P-21, `public.shop_fees`, money 0061/0068): fixed amounts a
//  shop adds to jobs, quotes and invoices as ordinary lines. Every member
//  may read the names and amounts; owners/admins edit them on the web. A fee
//  is added with `add_fee_line` (managers+), which prices the line on the
//  server — the app never sends the amount.
//
//  Shared model: the jobs agent owns it; the money screens (quote/invoice fee
//  pickers) read it.
//

import Foundation

// table: shop_fees
struct JobsShopFee: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var name: String
    var amountCents: Int
    var taxable: Bool
    /// `fee_apply_location`: none | shop | mobile | both.
    var autoApply: String
    var active: Bool
    var sort: Int
    var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case name
        case amountCents = "amount_cents"
        case taxable
        case autoApply = "auto_apply"
        case active
        case sort
        case archivedAt = "archived_at"
    }

    static let selectColumns = "id,shop_id,name,amount_cents,taxable,auto_apply,active,sort,archived_at"

    /// Offered in pickers: active and not archived.
    var isSelectable: Bool { active && archivedAt == nil }

    /// "Added automatically to mobile jobs", or nil for hand-added fees.
    var autoApplyText: String? {
        switch autoApply {
        case "shop": return "Added automatically to in-shop jobs"
        case "mobile": return "Added automatically to mobile jobs"
        case "both": return "Added automatically to every job"
        default: return nil
        }
    }

    /// The fee kinds `add_fee_line` accepts as `p_doc_kind`.
    enum DocumentKind: String, Sendable {
        case job
        case quote
        case invoice
    }
}
