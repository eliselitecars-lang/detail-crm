import XCTest
@testable import DetailCore

private struct Person: Identifiable, Equatable {
    let id: UUID
    let name: String
}

final class LinkedRecordTests: XCTestCase {

    private let linked = UUID()

    func testAnUnlinkedFieldSavesNothing() {
        let field = LinkedRecord<Person>()
        XCTAssertNil(field.id)
        XCTAssertEqual(field.display, .none)
    }

    func testALinkedRowNeedsItsRecordLoaded() {
        let field = LinkedRecord<Person>(id: linked)
        XCTAssertEqual(field.id, linked)
        XCTAssertEqual(field.display, .loading)
    }

    /// The finding: a failed lookup must not erase the link on save.
    func testAFailedLookupKeepsTheLinkedID() {
        var field = LinkedRecord<Person>(id: linked)
        field.lookupFailed(for: linked)
        XCTAssertEqual(field.id, linked)
        XCTAssertEqual(field.display, .failed)
        XCTAssertTrue(field.lookupFailed)

        field.retryingLookup()
        XCTAssertEqual(field.display, .loading)
        let person = Person(id: linked, name: "Ana")
        field.lookupFinished(person, for: linked)
        XCTAssertEqual(field.display, .record(person))
        XCTAssertEqual(field.id, linked)
    }

    func testARecordThatIsNotVisibleKeepsTheLink() {
        var field = LinkedRecord<Person>(id: linked)
        field.lookupFinished(nil, for: linked)
        XCTAssertEqual(field.id, linked)
        XCTAssertEqual(field.display, .unavailable)
    }

    func testOnlyTheUserChangesTheLink() {
        var field = LinkedRecord<Person>(id: linked)
        let other = Person(id: UUID(), name: "Ben")
        field.pick(other)
        XCTAssertEqual(field.id, other.id)
        XCTAssertEqual(field.display, .record(other))

        // A late answer for the old id changes nothing.
        field.lookupFinished(Person(id: linked, name: "Ana"), for: linked)
        field.lookupFailed(for: linked)
        XCTAssertEqual(field.id, other.id)
        XCTAssertEqual(field.display, .record(other))

        field.remove()
        XCTAssertNil(field.id)
        XCTAssertEqual(field.display, .none)
    }
}

final class MemberDiscountChoiceTests: XCTestCase {

    func testAOneOffJobFollowsTheSwitch() {
        XCTAssertTrue(MemberDiscountChoice.applies(switchOn: true, repeating: false))
        XCTAssertFalse(MemberDiscountChoice.applies(switchOn: false, repeating: false))
        XCTAssertTrue(MemberDiscountChoice.isOptional(repeating: false))
    }

    /// The server prices every visit of a series with the member discount,
    /// so the app must show (and cannot offer to drop) it.
    func testARepeatingJobAlwaysGetsTheDiscount() {
        XCTAssertTrue(MemberDiscountChoice.applies(switchOn: false, repeating: true))
        XCTAssertTrue(MemberDiscountChoice.applies(switchOn: true, repeating: true))
        XCTAssertFalse(MemberDiscountChoice.isOptional(repeating: true))
        XCTAssertFalse(MemberDiscountChoice.repeatingNote.isEmpty)
    }
}
