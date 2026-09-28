import XCTest
@testable import DetailCore

private struct Row: Equatable {
    let id: Int
    let name: String
}

private struct Boom: Error, Equatable {}

final class ListPagingTests: XCTestCase {

    // MARK: ListPage.trim

    /// A shop with 301 memberships: the first page shows 100 and says more
    /// exist, the last page (1 row) says none follow.
    func testTrimDropsTheExtraRowAndReportsMore() {
        let first = ListPage.trim(Array(0..<101), pageSize: 100)
        XCTAssertEqual(first.rows, Array(0..<100))
        XCTAssertTrue(first.hasMore)

        let exact = ListPage.trim(Array(0..<100), pageSize: 100)
        XCTAssertEqual(exact.rows.count, 100)
        XCTAssertFalse(exact.hasMore)

        let last = ListPage.trim([300], pageSize: 100)
        XCTAssertEqual(last.rows, [300])
        XCTAssertFalse(last.hasMore)

        let empty = ListPage.trim([Int](), pageSize: 100)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertFalse(empty.hasMore)
    }

    /// Paging a 301-row list with trim + offset = rows shown reaches every
    /// row exactly once, including the oldest.
    func testPagingReachesTheOldestRow() {
        let table = Array((0..<301).reversed()) // newest first
        var shown: [Int] = []
        var hasMore = true
        var requests = 0
        while hasMore {
            let start = shown.count
            let reply = Array(table[start..<min(start + 101, table.count)])
            let page = ListPage.trim(reply, pageSize: 100)
            shown = ListPage.appending(shown, page.rows, id: { $0 })
            hasMore = page.hasMore
            requests += 1
        }
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(shown, table)
        XCTAssertEqual(shown.last, 0)
    }

    // MARK: ListPage.appending

    func testAppendingSkipsRowsAlreadyShown() {
        let existing = [Row(id: 1, name: "a"), Row(id: 2, name: "b")]
        // A row inserted meanwhile shifted the offsets: row 2 comes again.
        let page = [Row(id: 2, name: "b (again)"), Row(id: 3, name: "c"), Row(id: 3, name: "c dup")]
        let merged = ListPage.appending(existing, page, id: \.id)
        XCTAssertEqual(merged.map(\.id), [1, 2, 3])
        XCTAssertEqual(merged[1].name, "b", "the row already shown is kept")
        XCTAssertEqual(merged[2].name, "c")
    }

    // MARK: IDChunks

    /// 300 vehicle ids (about 11 KB of URL in one request) become three
    /// requests of 100.
    func testChunksSplitIntoBatchesOfAHundred() {
        let ids = (0..<300).map { _ in UUID() }
        let chunks = IDChunks.chunks(ids)
        XCTAssertEqual(chunks.map(\.count), [100, 100, 100])
        XCTAssertEqual(chunks.flatMap { $0 }, ids)
    }

    func testChunksDropDuplicatesKeepingFirstOrder() {
        let chunks = IDChunks.chunks([3, 1, 3, 2, 1, 4, 5], size: 2)
        XCTAssertEqual(chunks, [[3, 1], [2, 4], [5]])
    }

    func testChunksOfNothingIsNoRequest() {
        XCTAssertTrue(IDChunks.chunks([Int]()).isEmpty)
        XCTAssertEqual(IDChunks.chunks([7, 7, 7]), [[7]])
    }

    // MARK: SideLoad

    func testSideLoadReturnsTheValue() async throws {
        let result = try await SideLoad.attempt { 42 }
        XCTAssertEqual(try result.get(), 42)
    }

    /// Saved cards failing to load is reported, not turned into "no cards".
    func testSideLoadReportsAFailureInsteadOfHidingIt() async throws {
        let result: Result<[Int], Error> = try await SideLoad.attempt { throw Boom() }
        switch result {
        case .success:
            XCTFail("a failed load must not look like an empty list")
        case .failure(let error):
            XCTAssertEqual(error as? Boom, Boom())
        }
    }

    func testSideLoadRethrowsCancellation() async {
        do {
            _ = try await SideLoad.attempt { () async throws -> Int in throw CancellationError() }
            XCTFail("cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSideLoadInACancelledTaskRethrows() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await SideLoad.attempt { () async throws -> Int in throw Boom() }
                return false
            } catch {
                return error is Boom
            }
        }
        let rethrown = await task.value
        XCTAssertTrue(rethrown, "a failure in a cancelled task is not shown as a problem")
    }
}
