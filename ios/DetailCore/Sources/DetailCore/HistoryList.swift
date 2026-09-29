//
//  HistoryList.swift
//  DetailCore
//
//  A customer's history (jobs, quotes, invoices on the customer screen) is
//  read newest first, one page at a time, with the exact count the server
//  reports. A fleet or dealership customer can have more rows than one
//  page: the screen must say how many exist, offer the older ones, and
//  never label a cut list "all". The overview tiles above it (completed
//  jobs, open balance) count every row, so the list has to be able to
//  reach every row they count.
//

import Foundation

public struct HistoryList<Row> {

    /// The rows loaded so far, newest first.
    public private(set) var rows: [Row]
    /// Every matching row the server counted (never less than `rows`).
    public private(set) var total: Int

    /// The first page. Without a count (the server didn't send one) the
    /// list is taken as complete only when the page wasn't full.
    public init(rows: [Row], total: Int?, pageSize: Int = HistoryListing.pageSize) {
        self.rows = rows
        if let total {
            self.total = max(total, rows.count)
        } else {
            // A full page with no count: at least one more row may exist.
            self.total = rows.count >= pageSize ? rows.count + 1 : rows.count
        }
    }

    /// More rows exist on the server than are loaded.
    public var hasMore: Bool { total > rows.count }

    /// Rows not loaded yet.
    public var remaining: Int { max(0, total - rows.count) }

    /// Offset of the next page.
    public var nextOffset: Int { rows.count }

    public var isEmpty: Bool { rows.isEmpty && total == 0 }

    /// Adds the next page. Rows already listed are skipped (a row added
    /// meanwhile shifts the offsets by one). An empty page ends the list
    /// even when the earlier count said more (rows were removed meanwhile).
    public mutating func append<ID: Hashable>(
        page: [Row],
        total: Int?,
        pageSize: Int = HistoryListing.pageSize,
        id: (Row) -> ID
    ) {
        let before = rows.count
        rows = ListPage.appending(rows, page, id: id)
        if page.isEmpty || rows.count == before {
            // Nothing new came back: the list ends here (and "Load more"
            // can't ask for the same page forever).
            self.total = rows.count
        } else if let total {
            self.total = max(total, rows.count)
        } else {
            self.total = page.count >= pageSize ? rows.count + 1 : rows.count
        }
    }
}

extension HistoryList: Equatable where Row: Equatable {}

/// Page size and the words a history list uses about itself.
public enum HistoryListing {

    /// Rows asked for per page on the customer screen.
    public static let pageSize = 50

    /// The expander under a collapsed list: "Show all 12 jobs" only when
    /// every row is loaded; otherwise "Show the 50 most recent jobs".
    public static func expandTitle(loaded: Int, total: Int, plural: String) -> String {
        if total > loaded {
            return "Show the \(loaded) most recent \(plural)"
        }
        return "Show all \(loaded) \(plural)"
    }

    /// Under a list that doesn't hold every row: "Showing the 50 most
    /// recent of 80 jobs." Nil when the list is complete.
    public static func truncationNotice(loaded: Int, total: Int, plural: String) -> String? {
        guard total > loaded else { return nil }
        return "Showing the \(loaded) most recent of \(total) \(plural)."
    }

    /// The button that loads the next page: "Load 30 more" (at most a
    /// page).
    public static func loadMoreTitle(remaining: Int, pageSize: Int) -> String {
        "Load \(min(max(remaining, 1), pageSize)) more"
    }
}
