import XCTest
@testable import DetailCore

final class CompactTitleTests: XCTestCase {

    func testOneWordPerLine() {
        XCTAssertEqual(CompactTitle.lines("Christopher Lee", maxLines: 3), ["Christopher", "Lee"])
        XCTAssertEqual(CompactTitle.lines("Busy", maxLines: 3), ["Busy"])
    }

    func testLastLineCarriesTheRemainingWords() {
        XCTAssertEqual(CompactTitle.lines("Mary Ann Van Dyke", maxLines: 3), ["Mary", "Ann", "Van Dyke"])
        XCTAssertEqual(CompactTitle.lines("Mary Ann Van Dyke", maxLines: 1), ["Mary Ann Van Dyke"])
        XCTAssertEqual(CompactTitle.lines("Ana María Ruiz", maxLines: 3), ["Ana", "María", "Ruiz"])
    }

    func testWhitespaceCollapsesAndWordsStayWhole() {
        XCTAssertEqual(CompactTitle.lines("  Sarah \n Nguyen\t", maxLines: 3), ["Sarah", "Nguyen"])
        XCTAssertEqual(CompactTitle.lines("Smith-Jones", maxLines: 3), ["Smith-Jones"])
    }

    func testEmptyTitleOrNoLines() {
        XCTAssertEqual(CompactTitle.lines("", maxLines: 3), [])
        XCTAssertEqual(CompactTitle.lines("   ", maxLines: 3), [])
        XCTAssertEqual(CompactTitle.lines("Ryan Mitchell", maxLines: 0), [])
    }
}
