import XCTest
@testable import DetailCore

final class MarketingAddressTests: XCTestCase {

    func testAddressNeedsStreetAndCityLikeTheServer() {
        // comms_shop_postal_address (0119): btrim'd street line and city.
        XCTAssertTrue(MarketingAddress.isOnFile(addressLine1: "12 Main St", city: "Birmingham"))
        XCTAssertFalse(MarketingAddress.isOnFile(addressLine1: nil, city: "Birmingham"))
        XCTAssertFalse(MarketingAddress.isOnFile(addressLine1: "12 Main St", city: nil))
        XCTAssertFalse(MarketingAddress.isOnFile(addressLine1: "   ", city: "Birmingham"))
        XCTAssertFalse(MarketingAddress.isOnFile(addressLine1: "12 Main St", city: ""))
        XCTAssertFalse(MarketingAddress.isOnFile(addressLine1: nil, city: nil))
        // btrim drops spaces only: a tab is not blank to the server.
        XCTAssertTrue(MarketingAddress.isOnFile(addressLine1: "\t", city: "Birmingham"))
    }

    func testOnlyEnabledEmailFollowupsAreBlocked() {
        XCTAssertTrue(MarketingAddress.isBlockedFollowup(channel: "email", enabled: true, addressOnFile: false))
        XCTAssertTrue(MarketingAddress.isBlockedFollowup(channel: "EMAIL", enabled: true, addressOnFile: false))
        XCTAssertFalse(MarketingAddress.isBlockedFollowup(channel: "email", enabled: false, addressOnFile: false), "off stays Off")
        XCTAssertFalse(MarketingAddress.isBlockedFollowup(channel: "sms", enabled: true, addressOnFile: false), "texts are not affected")
        XCTAssertFalse(MarketingAddress.isBlockedFollowup(channel: "email", enabled: true, addressOnFile: true))
        XCTAssertFalse(MarketingAddress.isBlockedFollowup(channel: "email", enabled: true, addressOnFile: nil), "unknown: no warning")
    }

    func testWording() {
        XCTAssertEqual(
            MarketingAddress.followupsWarning(canEditBusinessProfile: true),
            "The email follow-ups here are on but aren't being sent. The law requires your shop's mailing address in every marketing email, and there's no street address and city on file. Add the street address and city in Settings → Business profile."
        )
        XCTAssertTrue(MarketingAddress.followupsWarning(canEditBusinessProfile: false)
            .hasSuffix("Ask an owner or admin to add it in Settings → Business profile."))
        XCTAssertTrue(MarketingAddress.missingText.contains("rebooking and maintenance follow-up emails are skipped"))
        XCTAssertTrue(MarketingAddress.missingText.hasSuffix("Texts and other emails are not affected."))
        XCTAssertEqual(MarketingAddress.notSentBadge, "Not sent")
    }
}
