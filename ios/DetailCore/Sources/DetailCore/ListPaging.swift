//
//  ListPaging.swift
//  DetailCore
//
//  Helpers for lists that are read a page at a time ("Load more") and for
//  look-ups by many ids.
//
//  * `ListPage.trim` — a page is requested with one extra row; the extra
//    row only tells whether another page exists and is dropped.
//  * `ListPage.appending` — adds the next page to what is shown, skipping
//    rows already listed (a row inserted meanwhile shifts the offsets, so
//    the next page can repeat the last row of the previous one).
//  * `IDChunks.chunks` — splits an id list into de-duplicated batches for
//    `.in("id", ...)` filters. Every id is a 36-character UUID in the
//    request URL, so an unbounded list can make the request too long for
//    the gateway to accept; chunks of 100 stay well under that.
//

import Foundation

public enum ListPage {

    /// Rows asked for per list page by the paged staff lists.
    public static let defaultPageSize = 100

    /// Splits a reply requested with `pageSize + 1` rows: the rows to show
    /// and whether more rows follow.
    public static func trim<Row>(_ rows: [Row], pageSize: Int) -> (rows: [Row], hasMore: Bool) {
        precondition(pageSize > 0, "pageSize must be positive")
        guard rows.count > pageSize else { return (rows, false) }
        return (Array(rows.prefix(pageSize)), true)
    }

    /// `existing` followed by the rows of `page` that aren't listed yet.
    public static func appending<Row, ID: Hashable>(
        _ existing: [Row],
        _ page: [Row],
        id: (Row) -> ID
    ) -> [Row] {
        var known = Set(existing.map(id))
        var merged = existing
        for row in page where known.insert(id(row)).inserted {
            merged.append(row)
        }
        return merged
    }
}

public enum IDChunks {

    /// Ids per `.in(...)` request.
    public static let defaultSize = 100

    /// The distinct ids of `ids` (first occurrence order) in batches of at
    /// most `size`.
    public static func chunks<ID: Hashable>(_ ids: [ID], size: Int = defaultSize) -> [[ID]] {
        precondition(size > 0, "size must be positive")
        var seen = Set<ID>()
        let unique = ids.filter { seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: size).map { start in
            Array(unique[start..<min(start + size, unique.count)])
        }
    }
}

/// An optional part of a screen (saved cards, a pay-link token) loaded
/// next to the record it belongs to. A failure must not hide the record,
/// but it must not look like "there is nothing" either: the screen shows
/// the problem with a retry instead of silently leaving the action out.
public enum SideLoad {

    /// Runs `operation`; its error comes back as `.failure` so the caller
    /// can show it. Cancellation (the screen went away or reloaded) is
    /// rethrown rather than reported as a failure.
    public static func attempt<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Result<Value, Error> {
        do {
            return .success(try await operation())
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            return .failure(error)
        }
    }
}
