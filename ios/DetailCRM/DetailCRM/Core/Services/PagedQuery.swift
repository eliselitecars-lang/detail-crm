//
//  PagedQuery.swift
//  DetailCRM
//
//  Reads every row of a PostgREST query in pages. The server returns at
//  most `max_rows` (1,000 on hosted Supabase) rows per request whatever
//  `.limit(...)` asks for, so a list that must be complete (the catalog's
//  prices, which the price editor diffs against) is read with ranges and
//  an exact count; `PagedRows` (DetailCore) throws rather than return a
//  partial list.
//

import Foundation
import Supabase
import DetailCore

enum PagedQuery {

    /// Every row of `query`. The builder must select with
    /// `count: .exact` and order by a unique key (end with `id`) so pages
    /// neither overlap nor skip rows; it is rebuilt for each page.
    static func all<Row: Decodable>(
        pageSize: Int = PagedRows.defaultPageSize,
        _ query: () -> PostgrestTransformBuilder
    ) async throws -> [Row] {
        try await PagedRows.loadAll(pageSize: pageSize) { from, to in
            let response: PostgrestResponse<[Row]> = try await query()
                .range(from: from, to: to)
                .execute()
            return PagedRows.Page(rows: response.value, total: response.count)
        }
    }
}
