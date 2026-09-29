import XCTest
@testable import DetailCore

private struct Job: Equatable {
    let id: Int
}

final class HistoryListTests: XCTestCase {

    /// A fleet customer with 80 jobs: the first page holds the 50 newest,
    /// knows 30 more exist and never calls the list "all".
    func testFirstPageOfALongHistoryKnowsTheTotal() {
        let list = HistoryList(rows: (0..<50).map(Job.init), total: 80)
        XCTAssertEqual(list.rows.count, 50)
        XCTAssertEqual(list.total, 80)
        XCTAssertTrue(list.hasMore)
        XCTAssertEqual(list.remaining, 30)
        XCTAssertEqual(list.nextOffset, 50)
        XCTAssertEqual(
            HistoryListing.expandTitle(loaded: list.rows.count, total: list.total, plural: "jobs"),
            "Show the 50 most recent jobs"
        )
        XCTAssertEqual(
            HistoryListing.truncationNotice(loaded: list.rows.count, total: list.total, plural: "jobs"),
            "Showing the 50 most recent of 80 jobs."
        )
        XCTAssertEqual(HistoryListing.loadMoreTitle(remaining: list.remaining, pageSize: 50), "Load 30 more")
    }

    /// Loading the next page reaches the oldest row; then it's complete.
    func testLoadingMoreReachesEveryRow() {
        var list = HistoryList(rows: (0..<50).map(Job.init), total: 80)
        list.append(page: (50..<80).map(Job.init), total: 80, id: \.id)
        XCTAssertEqual(list.rows.map(\.id), Array(0..<80))
        XCTAssertFalse(list.hasMore)
        XCTAssertEqual(HistoryListing.expandTitle(loaded: 80, total: list.total, plural: "jobs"), "Show all 80 jobs")
        XCTAssertNil(HistoryListing.truncationNotice(loaded: 80, total: list.total, plural: "jobs"))
    }

    /// A short history is complete from the start.
    func testShortHistoryIsComplete() {
        let list = HistoryList(rows: (0..<12).map(Job.init), total: 12)
        XCTAssertFalse(list.hasMore)
        XCTAssertEqual(HistoryListing.expandTitle(loaded: 12, total: 12, plural: "invoices"), "Show all 12 invoices")
        XCTAssertTrue(HistoryList<Job>(rows: [], total: 0).isEmpty)
    }

    /// A job added meanwhile shifts the offsets: the repeated row is
    /// skipped, and the new count is taken.
    func testAppendSkipsRowsAlreadyListed() {
        var list = HistoryList(rows: (0..<50).map(Job.init), total: 80)
        list.append(page: (49..<99).map(Job.init), total: 101, id: \.id)
        XCTAssertEqual(list.rows.count, 99)
        XCTAssertEqual(Set(list.rows.map(\.id)).count, 99)
        XCTAssertEqual(list.total, 101)
        XCTAssertTrue(list.hasMore)
    }

    /// Rows removed meanwhile: an empty page (or one with nothing new)
    /// ends the list, so "Load more" can't loop on the same page.
    func testEmptyOrRepeatedPageEndsTheList() {
        var list = HistoryList(rows: (0..<50).map(Job.init), total: 80)
        list.append(page: [], total: 80, id: \.id)
        XCTAssertFalse(list.hasMore)
        XCTAssertEqual(list.total, 50)

        var repeated = HistoryList(rows: (0..<50).map(Job.init), total: 80)
        repeated.append(page: (0..<50).map(Job.init), total: 80, id: \.id)
        XCTAssertFalse(repeated.hasMore)
    }

    /// Without a count, a full page means "maybe more"; a short one ends it.
    func testWithoutACountAFullPageMayHaveMore() {
        var list = HistoryList(rows: (0..<50).map(Job.init), total: nil, pageSize: 50)
        XCTAssertTrue(list.hasMore)
        list.append(page: (50..<60).map(Job.init), total: nil, pageSize: 50, id: \.id)
        XCTAssertFalse(list.hasMore)
        XCTAssertEqual(list.rows.count, 60)

        let short = HistoryList(rows: (0..<7).map(Job.init), total: nil, pageSize: 50)
        XCTAssertFalse(short.hasMore)
    }

    /// The count can never be below what is listed.
    func testTotalNeverBelowRows() {
        let list = HistoryList(rows: (0..<5).map(Job.init), total: 3)
        XCTAssertEqual(list.total, 5)
        XCTAssertFalse(list.hasMore)
    }

    func testLoadMoreTitleIsAtMostAPage() {
        XCTAssertEqual(HistoryListing.loadMoreTitle(remaining: 500, pageSize: 50), "Load 50 more")
        XCTAssertEqual(HistoryListing.loadMoreTitle(remaining: 1, pageSize: 50), "Load 1 more")
    }
}
