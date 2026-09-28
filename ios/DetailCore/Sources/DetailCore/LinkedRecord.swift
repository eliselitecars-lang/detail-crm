import Foundation

/// A form field that links another record (an event's customer, …) by id.
///
/// The id is what gets saved; the loaded record only labels the field. So a
/// lookup that failed (network blip, timeout) or found nothing visible never
/// clears the link: saving without touching the field keeps the id the row
/// already had, the way the web keeps `customer_id` from the row. Only the
/// person's own Remove, or picking another record, changes it.
public struct LinkedRecord<Record: Identifiable & Equatable>: Equatable where Record.ID == UUID {

    /// What the field shows for the linked id.
    public enum Display: Equatable {
        /// Nothing is linked.
        case none
        /// The linked record, loaded.
        case record(Record)
        /// Linked, not loaded yet.
        case loading
        /// Linked, but the lookup failed: offer a retry (the link is kept).
        case failed
        /// Linked, but the record is not visible (removed or hidden): the
        /// link is kept until the person removes it.
        case unavailable
    }

    /// The id saved with the form (nil: no link).
    public private(set) var id: UUID?
    public private(set) var record: Record?
    public private(set) var lookupFailed = false
    private var lookupDone = false

    /// A field for a row that links `id` (nil: nothing linked yet).
    public init(id: UUID? = nil) {
        self.id = id
        lookupDone = id == nil
    }

    public var display: Display {
        guard id != nil else { return .none }
        if let record { return .record(record) }
        if lookupFailed { return .failed }
        return lookupDone ? .unavailable : .loading
    }

    /// The lookup for `id` answered: the record, or nil when not visible.
    /// An answer for another id (the person picked or removed meanwhile) is
    /// ignored.
    public mutating func lookupFinished(_ found: Record?, for lookedUp: UUID) {
        guard lookedUp == id else { return }
        record = found
        lookupFailed = false
        lookupDone = true
    }

    /// The lookup for `id` failed: the link stays, the field offers a retry.
    public mutating func lookupFailed(for lookedUp: UUID) {
        guard lookedUp == id, record == nil else { return }
        lookupFailed = true
        lookupDone = false
    }

    /// A retry of a failed lookup is starting.
    public mutating func retryingLookup() {
        lookupFailed = false
    }

    /// The person picked a record.
    public mutating func pick(_ picked: Record) {
        id = picked.id
        record = picked
        lookupFailed = false
        lookupDone = true
    }

    /// The person removed the link (or the form no longer allows one).
    public mutating func remove() {
        id = nil
        record = nil
        lookupFailed = false
        lookupDone = true
    }
}
