import XCTest
@testable import DetailCore

/// A PostgREST stand-in: `rows` in order, at most `cap` per reply however
/// many are asked for (like `max_rows`), with an exact count when asked.
private final class CappedTable {
    var rows: [Int]
    let cap: Int
    let reportsTotal: Bool
    var requests: [(Int, Int)] = []
    /// Runs before each reply (to change the table mid-load).
    var beforeReply: ((CappedTable) -> Void)?

    init(count: Int, cap: Int = 1000, reportsTotal: Bool = true) {
        rows = Array(0..<count)
        self.cap = cap
        self.reportsTotal = reportsTotal
    }

    func fetch(_ from: Int, _ to: Int) -> PagedRows.Page<Int> {
        requests.append((from, to))
        beforeReply?(self)
        let end = min(to, from + cap - 1, rows.count - 1)
        let slice = from <= end ? Array(rows[from...end]) : []
        return PagedRows.Page(rows: slice, total: reportsTotal ? rows.count : nil)
    }
}

final class PagedRowsTests: XCTestCase {

    /// 170 services x 6 vehicle sizes = 1,020 price rows: one capped
    /// request would drop 20 of them; paging reads them all.
    func testAListLongerThanTheServerCapIsReadCompletely() async throws {
        let table = CappedTable(count: 1020)
        let rows = try await PagedRows.loadAll { table.fetch($0, $1) }
        XCTAssertEqual(rows, Array(0..<1020))
        XCTAssertEqual(table.requests.map(\.0), [0, 500, 1000])
        XCTAssertEqual(table.requests.map(\.1), [499, 999, 1499])
    }

    func testAShortListTakesOneRequest() async throws {
        let table = CappedTable(count: 42)
        let rows = try await PagedRows.loadAll { table.fetch($0, $1) }
        XCTAssertEqual(rows.count, 42)
        XCTAssertEqual(table.requests.count, 1)
    }

    func testAnEmptyListTakesOneRequest() async throws {
        let table = CappedTable(count: 0)
        let rows = try await PagedRows.loadAll { table.fetch($0, $1) }
        XCTAssertEqual(rows, [])
        XCTAssertEqual(table.requests.count, 1)
    }

    func testAnExactMultipleOfThePageSizeStopsAtTheTotal() async throws {
        let table = CappedTable(count: 1000)
        let rows = try await PagedRows.loadAll { table.fetch($0, $1) }
        XCTAssertEqual(rows.count, 1000)
        XCTAssertEqual(table.requests.count, 2)
    }

    /// A server capped below the page size (say max_rows = 100) returns
    /// short pages; with a total the loader keeps going instead of
    /// mistaking the first short page for the end.
    func testAServerCapBelowThePageSizeStillReadsEverything() async throws {
        let table = CappedTable(count: 350, cap: 100)
        let rows = try await PagedRows.loadAll { table.fetch($0, $1) }
        XCTAssertEqual(rows, Array(0..<350))
        XCTAssertEqual(table.requests.map(\.0), [0, 100, 200, 300])
    }

    func testWithoutATotalAShortPageEndsTheList() async throws {
        let table = CappedTable(count: 1020, reportsTotal: false)
        let rows = try await PagedRows.loadAll { table.fetch($0, $1) }
        XCTAssertEqual(rows, Array(0..<1020))
        XCTAssertEqual(table.requests.count, 3)
    }

    /// Rows deleted between pages shift the rest forward; the loader
    /// refuses the list instead of returning one with rows missing.
    func testRowsRemovedMidLoadFailInsteadOfReturningAPartialList() async throws {
        let table = CappedTable(count: 1020)
        var replies = 0
        table.beforeReply = { table in
            replies += 1
            // Between the first and second page another device removes
            // one row the first page already returned, but the total of
            // the first reply is what the loader is working towards.
            if replies == 2 { table.rows.removeFirst() }
        }
        do {
            _ = try await PagedRows.loadAll { from, to -> PagedRows.Page<Int> in
                let page = table.fetch(from, to)
                // Report the original total, as a count taken before the
                // delete would.
                return PagedRows.Page(rows: page.rows, total: 1020)
            }
            XCTFail("expected incomplete")
        } catch let failure as PagedRows.Failure {
            XCTAssertEqual(failure, .incomplete(expected: 1020, received: 1019))
            XCTAssertNotNil(failure.errorDescription)
        }
    }

    func testAListOverTheRowLimitIsRefused() async throws {
        let table = CappedTable(count: 120)
        do {
            _ = try await PagedRows.loadAll(pageSize: 50, rowLimit: 100) { table.fetch($0, $1) }
            XCTFail("expected tooManyRows")
        } catch let failure as PagedRows.Failure {
            XCTAssertEqual(failure, .tooManyRows(total: 120, limit: 100))
            XCTAssertEqual(table.requests.count, 1)
        }
    }

    func testWithoutATotalTheRowLimitStillStopsTheLoop() async throws {
        let table = CappedTable(count: 10_000, reportsTotal: false)
        do {
            _ = try await PagedRows.loadAll(pageSize: 50, rowLimit: 100) { table.fetch($0, $1) }
            XCTFail("expected tooManyRows")
        } catch let failure as PagedRows.Failure {
            XCTAssertEqual(failure, .tooManyRows(total: 100, limit: 100))
            XCTAssertEqual(table.requests.count, 2)
        }
    }

    func testFetchErrorsPropagate() async {
        struct Boom: Error {}
        do {
            _ = try await PagedRows.loadAll { (_: Int, _: Int) -> PagedRows.Page<Int> in throw Boom() }
            XCTFail("expected the fetch error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }
}
