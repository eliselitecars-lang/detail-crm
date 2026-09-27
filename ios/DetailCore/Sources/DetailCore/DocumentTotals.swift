import Foundation

/// One priced line on a job, quote or invoice, as far as totals are
/// concerned. Mirrors `job_line_items` / `quote_line_items` /
/// `invoice_line_items` (SPEC §4.4–4.5).
public struct TotalsLine: Equatable, Sendable {
    /// `numeric(10,2)`; values with more precision are rounded to hundredths
    /// half away from zero, exactly as Postgres stores them.
    public var quantity: Decimal
    public var unitPriceCents: Int
    /// Per-line discount in cents (never negative).
    public var discountCents: Int
    public var taxable: Bool
    /// Quote lines only: an optional upsell counts toward totals only when
    /// `selected` is true. Non-optional lines always count.
    public var isOptional: Bool
    public var isSelected: Bool

    public init(
        quantity: Decimal = 1,
        unitPriceCents: Int,
        discountCents: Int = 0,
        taxable: Bool = true,
        isOptional: Bool = false,
        isSelected: Bool = true
    ) {
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.discountCents = discountCents
        self.taxable = taxable
        self.isOptional = isOptional
        self.isSelected = isSelected
    }

    /// Whether this line participates in the document totals.
    public var counts: Bool { !isOptional || isSelected }

    /// `round(quantity × unit_price)` half away from zero.
    public var grossCents: Int {
        let hundredths = Self.quantityHundredths(quantity)
        return Rounding.divideHalfAwayFromZero(hundredths * unitPriceCents, 100)
    }

    /// `round(quantity × unit_price) − discount`, never below zero.
    public var lineTotalCents: Int {
        max(0, grossCents - max(0, discountCents))
    }

    /// Quantity as an exact integer number of hundredths (1.5 -> 150).
    static func quantityHundredths(_ quantity: Decimal) -> Int {
        let scaled = Rounding.round(quantity * 100, scale: 0)
        return NSDecimalNumber(decimal: scaled).intValue
    }
}

/// A document-level discount (manual or coupon), applied to the subtotal.
public enum DocumentDiscount: Equatable, Sendable {
    case none
    /// Fixed amount in cents.
    case fixed(cents: Int)
    /// Percentage in basis points (10% = 1000).
    case percent(basisPoints: Int)

    /// Builds a discount from the database pair (`discount_kind`, value):
    /// `none` | `percent` (value in basis points) | `fixed` (value in cents).
    /// Unknown kinds are treated as no discount.
    public init(kind: String, value: Int) {
        switch kind {
        case "percent": self = .percent(basisPoints: value)
        case "fixed": self = .fixed(cents: value)
        default: self = .none
        }
    }

    /// The `discount_kind` enum value for this discount.
    public var kindRawValue: String {
        switch self {
        case .none: return "none"
        case .percent: return "percent"
        case .fixed: return "fixed"
        }
    }

    /// The discount in cents for a given subtotal: never negative and never
    /// more than the subtotal. (The server rejects negative values and
    /// percentages above 10000 bps outright; previews clamp instead.)
    public func cents(forSubtotal subtotal: Int) -> Int {
        let raw: Int
        switch self {
        case .none:
            raw = 0
        case .fixed(let cents):
            raw = cents
        case .percent(let bps):
            raw = Rounding.divideHalfAwayFromZero(subtotal * max(0, bps), 10_000)
        }
        return min(max(0, raw), max(0, subtotal))
    }
}

/// Totals for a job, quote or invoice — the exact client-side mirror of
/// `public.compute_document_totals` (SPEC §4.5). Used only for live previews; the
/// server is always the source of truth and clients never send totals.
///
///     line_total   = round(quantity × unit_price) − line discount (≥ 0)
///     subtotal     = Σ line_total
///     discount     = document discount, capped at subtotal
///     taxable_base = Σ taxable line_total − round(discount × Σ taxable / subtotal)
///     tax          = round(taxable_base × tax_rate_bps / 10000)
///     total        = subtotal − discount + tax
///
/// All rounding is half away from zero (Postgres `round(numeric)`).
public struct DocumentTotals: Equatable, Sendable {
    public let lineTotalsCents: [Int]
    public let subtotalCents: Int
    public let discountCents: Int
    public let taxableBaseCents: Int
    public let taxCents: Int
    public let totalCents: Int

    public init(lines: [TotalsLine], discount: DocumentDiscount = .none, taxRateBps: Int) {
        let counted = lines.map { $0.counts ? $0.lineTotalCents : 0 }
        let subtotal = counted.reduce(0, +)
        let taxableSum = zip(lines, counted).reduce(0) { sum, pair in
            pair.0.taxable ? sum + pair.1 : sum
        }
        let discount = discount.cents(forSubtotal: subtotal)
        let taxableDiscount: Int
        if subtotal > 0 && taxableSum > 0 && discount > 0 {
            taxableDiscount = Rounding.divideHalfAwayFromZero(discount * taxableSum, subtotal)
        } else {
            taxableDiscount = 0
        }
        let taxableBase = max(0, taxableSum - taxableDiscount)
        let tax = Rounding.divideHalfAwayFromZero(taxableBase * max(0, taxRateBps), 10_000)

        self.lineTotalsCents = counted
        self.subtotalCents = subtotal
        self.discountCents = discount
        self.taxableBaseCents = taxableBase
        self.taxCents = tax
        self.totalCents = subtotal - discount + tax
    }

    /// Balance owed: total − amount paid. Tips are tracked separately and
    /// never change the balance.
    public static func balanceCents(totalCents: Int, amountPaidCents: Int) -> Int {
        totalCents - amountPaidCents
    }
}
