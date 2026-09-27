//
//  Catalog.swift
//  DetailCRM
//
//  Service catalog (0005, SPEC §4.3): categories, services / packages /
//  add-ons / products, prices per vehicle category (a null category is the
//  base price) and checklist templates. Everyone in the shop reads the
//  catalog; managers and above edit it (RLS).
//

import Foundation

/// `service_kind`.
enum CatalogServiceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case service
    case package
    case addon
    case product

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .service: return "Service"
        case .package: return "Package"
        case .addon: return "Add-on"
        case .product: return "Product"
        }
    }

    var pluralName: String {
        switch self {
        case .service: return "Services"
        case .package: return "Packages"
        case .addon: return "Add-ons"
        case .product: return "Products"
        }
    }

    var systemImage: String {
        switch self {
        case .service: return "sparkles"
        case .package: return "shippingbox"
        case .addon: return "plus.square.on.square"
        case .product: return "bag"
        }
    }
}

// table: service_categories
struct ServiceCategory: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var name: String
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case name
        case sort
    }

    static let selectColumns = "id,shop_id,name,sort"
}

/// A row of `services` (services, packages, add-ons and products).
// table: services
struct CatalogItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var categoryID: UUID?
    var name: String
    var description: String?
    var kind: CatalogServiceKind
    var durationMinutes: Int
    var taxable: Bool
    var onlineBookable: Bool
    var active: Bool
    var sort: Int
    var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case categoryID = "category_id"
        case name
        case description
        case kind
        case durationMinutes = "duration_minutes"
        case taxable
        case onlineBookable = "online_bookable"
        case active
        case sort
        case archivedAt = "archived_at"
    }

    static let selectColumns = [
        "id", "shop_id", "category_id", "name", "description", "kind", "duration_minutes",
        "taxable", "online_bookable", "active", "sort", "archived_at",
    ].joined(separator: ",")
}

/// A price row: `vehicleCategoryID == nil` is the service's base price.
// table: service_prices
struct ServicePrice: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var serviceID: UUID
    var vehicleCategoryID: UUID?
    var priceCents: Int
    var durationMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case serviceID = "service_id"
        case vehicleCategoryID = "vehicle_category_id"
        case priceCents = "price_cents"
        case durationMinutes = "duration_minutes"
    }

    static let selectColumns = "id,shop_id,service_id,vehicle_category_id,price_cents,duration_minutes"
}

/// Shop-defined vehicle size classes used as price columns (read here
/// only; the Customers feature owns vehicle editing).
// table: vehicle_categories
struct CatalogVehicleCategory: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sort
    }

    static let selectColumns = "id,name,sort"
}

/// One item of a checklist template (`{id, label}` in the jsonb array).
struct ChecklistTemplateItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var label: String
}

// table: checklist_templates
struct ChecklistTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var name: String
    var items: [ChecklistTemplateItem]
    var serviceID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case name
        case items
        case serviceID = "service_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        shopID = try container.decode(UUID.self, forKey: .shopID)
        name = try container.decode(String.self, forKey: .name)
        items = (try? container.decode([ChecklistTemplateItem].self, forKey: .items)) ?? []
        serviceID = try container.decodeIfPresent(UUID.self, forKey: .serviceID)
    }

    static let selectColumns = "id,shop_id,name,items,service_id"
}

/// Everything the Catalog screen shows, loaded together.
struct CatalogSnapshot: Hashable, Sendable {
    var categories: [ServiceCategory]
    var items: [CatalogItem]
    var prices: [ServicePrice]
    var vehicleCategories: [CatalogVehicleCategory]
    var checklists: [ChecklistTemplate]

    /// Non-archived items of `kind`, grouped by category (uncategorized
    /// last), each group sorted by `sort` then name.
    func groups(kind: CatalogServiceKind) -> [CatalogGroup] {
        let visible = items.filter { $0.kind == kind && $0.archivedAt == nil }
        var result: [CatalogGroup] = []
        let orderedCategories = categories.sorted { lhs, rhs in
            lhs.sort != rhs.sort ? lhs.sort < rhs.sort : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        for category in orderedCategories {
            let members = visible.filter { $0.categoryID == category.id }
            if !members.isEmpty {
                result.append(CatalogGroup(id: category.id.uuidString, title: category.name, items: Self.sorted(members)))
            }
        }
        let known = Set(categories.map(\.id))
        let loose = visible.filter { item in
            guard let categoryID = item.categoryID else { return true }
            return !known.contains(categoryID)
        }
        if !loose.isEmpty {
            result.append(CatalogGroup(id: "uncategorized-\(kind.rawValue)", title: "Uncategorized", items: Self.sorted(loose)))
        }
        return result
    }

    /// Price rows of one service: base first, then vehicle categories in order.
    func prices(for serviceID: UUID) -> [ServicePrice] {
        prices.filter { $0.serviceID == serviceID }
    }

    func basePrice(for serviceID: UUID) -> ServicePrice? {
        prices.first { $0.serviceID == serviceID && $0.vehicleCategoryID == nil }
    }

    func price(for serviceID: UUID, vehicleCategoryID: UUID) -> ServicePrice? {
        prices.first { $0.serviceID == serviceID && $0.vehicleCategoryID == vehicleCategoryID }
    }

    /// Lowest and highest configured price for a service (nil when unpriced).
    func priceRange(for serviceID: UUID) -> ClosedRange<Int>? {
        let amounts = prices(for: serviceID).map(\.priceCents)
        guard let low = amounts.min(), let high = amounts.max() else { return nil }
        return low...high
    }

    var sortedVehicleCategories: [CatalogVehicleCategory] {
        vehicleCategories.sorted { lhs, rhs in
            lhs.sort != rhs.sort ? lhs.sort < rhs.sort : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func categoryName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return categories.first { $0.id == id }?.name
    }

    func itemName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return items.first { $0.id == id }?.name
    }

    private static func sorted(_ items: [CatalogItem]) -> [CatalogItem] {
        items.sorted { lhs, rhs in
            lhs.sort != rhs.sort ? lhs.sort < rhs.sort : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

/// A titled group of catalog items (one category).
struct CatalogGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var items: [CatalogItem]
}

/// Simple edits managers make on the phone (name, duration, switches).
// table: services
struct CatalogItemUpdate: Encodable, Sendable {
    var name: String
    var durationMinutes: Int
    var active: Bool
    var onlineBookable: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case durationMinutes = "duration_minutes"
        case active
        case onlineBookable = "online_bookable"
    }
}

/// Insert payload for a new price row.
// table: service_prices
struct ServicePriceInsert: Encodable, Sendable {
    var shopID: UUID
    var serviceID: UUID
    var vehicleCategoryID: UUID?
    var priceCents: Int

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case serviceID = "service_id"
        case vehicleCategoryID = "vehicle_category_id"
        case priceCents = "price_cents"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shopID, forKey: .shopID)
        try container.encode(serviceID, forKey: .serviceID)
        try container.encode(vehicleCategoryID, forKey: .vehicleCategoryID)
        try container.encode(priceCents, forKey: .priceCents)
    }
}

/// Update payload for an existing price row.
// table: service_prices
struct ServicePriceUpdate: Encodable, Sendable {
    var priceCents: Int

    enum CodingKeys: String, CodingKey {
        case priceCents = "price_cents"
    }
}

/// What to do with one price cell when saving the price editor.
enum CatalogPriceChange: Equatable, Sendable {
    case insert(vehicleCategoryID: UUID?, priceCents: Int)
    case update(priceID: UUID, priceCents: Int)
    case delete(priceID: UUID)

    /// Compares the edited cells (`nil` = empty field) with the stored
    /// rows and returns the minimal set of writes.
    static func changes(
        existing: [ServicePrice],
        edited: [(vehicleCategoryID: UUID?, priceCents: Int?)]
    ) -> [CatalogPriceChange] {
        var result: [CatalogPriceChange] = []
        for cell in edited {
            let current = existing.first { $0.vehicleCategoryID == cell.vehicleCategoryID }
            switch (current, cell.priceCents) {
            case (nil, nil):
                continue
            case (nil, let cents?):
                result.append(.insert(vehicleCategoryID: cell.vehicleCategoryID, priceCents: cents))
            case (let row?, nil):
                result.append(.delete(priceID: row.id))
            case (let row?, let cents?):
                if row.priceCents != cents {
                    result.append(.update(priceID: row.id, priceCents: cents))
                }
            }
        }
        return result
    }
}
