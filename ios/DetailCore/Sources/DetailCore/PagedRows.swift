//
//  PagedRows.swift
//  DetailCore
//
//  Reads every row of a list that may be longer than one PostgREST reply.
//  PostgREST returns at most `max_rows` rows per request (1,000 on hosted
//  Supabase and in supabase/config.toml) whatever `.limit(...)` asks for,
//  and says nothing when it cuts a reply short. A screen that needs the
//  whole list (the catalog's prices, for example) has to page through it
//  with ranges and check the total the server reports.
//

import Foundation

public enum PagedRows {

    /// Rows asked for per request. Below the server cap, so a short page
    /// means the end of the list even when no total was reported.
    public static let defaultPageSize = 500

    /// Most rows one load accepts before giving up (keeps a runaway list
    /// from looping or holding the whole table in memory).
    public static let defaultRowLimit = 50_000

    /// One reply: its rows, and the total matching rows when the request
    /// asked for a count (`Prefer: count=exact`; `nil` otherwise).
    public struct Page<Row> {
        public var rows: [Row]
        public var total: Int?

        public init(rows: [Row], total: Int?) {
            self.rows = rows
            self.total = total
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// The list is longer than the load accepts.
        case tooManyRows(total: Int, limit: Int)
        /// The server reported more rows than it sent (rows changed while
        /// the list was being read). Reloading reads a consistent list.
        case incomplete(expected: Int, received: Int)

        public var errorDescription: String? {
            switch self {
            case .tooManyRows(let total, let limit):
                return "This list has \(total) rows, more than the app can load at once (\(limit))."
            case .incomplete:
                return "The list changed while it was loading. Pull to refresh to load it again."
            }
        }
    }

    /// Fetches pages until every row is read. `fetch(from, to)` requests
    /// the inclusive row range (use a stable, unique ordering such as `id`
    /// so pages neither overlap nor skip rows) and should ask for an exact
    /// count. With a total the loop advances by the rows actually received,
    /// so a server cap below `pageSize` still reads the whole list; without
    /// one it stops at the first short page. Throws instead of returning a
    /// partial list.
    public static func loadAll<Row>(
        pageSize: Int = defaultPageSize,
        rowLimit: Int = defaultRowLimit,
        fetch: (_ from: Int, _ to: Int) async throws -> Page<Row>
    ) async throws -> [Row] {
        precondition(pageSize > 0, "pageSize must be positive")
        var rows: [Row] = []
        var expected: Int?
        while true {
            let from = rows.count
            let page = try await fetch(from, from + pageSize - 1)
            if let total = page.total {
                expected = total
                if total > rowLimit {
                    throw Failure.tooManyRows(total: total, limit: rowLimit)
                }
            }
            rows.append(contentsOf: page.rows)
            if page.rows.isEmpty { break }
            if let expected {
                if rows.count >= expected { break }
            } else if page.rows.count < pageSize {
                break
            }
            if rows.count >= rowLimit {
                throw Failure.tooManyRows(total: expected ?? rows.count, limit: rowLimit)
            }
        }
        if let expected, rows.count < expected {
            throw Failure.incomplete(expected: expected, received: rows.count)
        }
        return rows
    }
}
