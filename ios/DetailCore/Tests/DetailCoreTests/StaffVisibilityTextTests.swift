import XCTest
@testable import DetailCore

/// Gate overrides (P-11), lead requests (P-9), legal links and payment
/// announcements: the text the iPhone shows (and says) for them.
final class StaffVisibilityTextTests: XCTestCase {

    // MARK: GateWaiver

    /// A completed job that skipped a required item and its after photos
    /// reads like the web job page.
    func testWaivedCompletionRequirements() {
        let waiver = GateWaiver(
            openRequiredItems: ["Wipe down door jambs", "Tire shine"],
            afterPhotos: .init(required: 4, have: 1)
        )
        XCTAssertEqual(waiver.sentences, [
            "Required checklist items not done: Wipe down door jambs, Tire shine",
            "4 \u{201C}after\u{201D} photos needed (1 so far)",
        ])
        XCTAssertEqual(GateWaiver.headline(to: .completed), "Moved to Completed without meeting its requirements")
    }

    func testWaivedStartRequirementsAndSingulars() {
        let waiver = GateWaiver(openRequiredItems: ["  Vacuum "], beforePhotos: .init(required: 1, have: 0))
        XCTAssertEqual(waiver.sentences, [
            "Required checklist item not done: Vacuum",
            "1 \u{201C}before\u{201D} photo needed (0 so far)",
        ])
        XCTAssertEqual(GateWaiver.headline(to: .inProgress), "Moved to In progress without meeting its requirements")
    }

    /// Parts that weren't short (or blank labels) are left out.
    func testNothingShortGivesNoSentences() {
        let waiver = GateWaiver(
            openRequiredItems: ["", "   "],
            afterPhotos: .init(required: 2, have: 2),
            beforePhotos: .init(required: 0, have: 0)
        )
        XCTAssertTrue(waiver.sentences.isEmpty)
    }

    func testReasonText() {
        XCTAssertEqual(GateWaiver.reasonText(nil), "No reason given.")
        XCTAssertEqual(GateWaiver.reasonText("  "), "No reason given.")
        XCTAssertEqual(GateWaiver.reasonText(" Customer declined photos "), "Customer declined photos")
    }

    // MARK: LeadRequestText

    func testLeadVehicleText() {
        XCTAssertEqual(LeadRequestText.vehicle(year: 2019, make: "Toyota", model: "Tacoma"), "2019 Toyota Tacoma")
        XCTAssertEqual(LeadRequestText.vehicle(year: nil, make: " Tesla ", model: ""), "Tesla")
        XCTAssertNil(LeadRequestText.vehicle(year: nil, make: nil, model: "  "))
    }

    func testLeadDescription() {
        XCTAssertEqual(
            LeadRequestText.description(shown: 10, total: 14),
            "The latest 10 of 14 requests sent from your lead forms."
        )
        XCTAssertEqual(
            LeadRequestText.description(shown: 2, total: 2),
            "Sent from your lead forms. Their details are kept here as they were sent."
        )
    }

    // MARK: LegalNotice

    func testLegalPagesOnTheWebApp() {
        let base = URL(string: "https://app.example.com")
        XCTAssertEqual(LegalNotice.privacyPolicy(webAppBase: base)?.absoluteString, "https://app.example.com/privacy")
        XCTAssertEqual(LegalNotice.termsOfService(webAppBase: base)?.absoluteString, "https://app.example.com/terms")
        let nested = URL(string: "https://example.com/crm/?x=1#top")
        XCTAssertEqual(LegalNotice.termsOfService(webAppBase: nested)?.absoluteString, "https://example.com/crm/terms")
        XCTAssertNil(LegalNotice.privacyPolicy(webAppBase: nil))
    }

    /// Every step that the Terms count as acceptance names the Terms and
    /// the Privacy Policy.
    func testEveryStepNamesBothDocuments() {
        for step in [LegalNotice.Step.createAccount, .signIn, .createShop, .joinShop, .createOrJoinShop] {
            let text = LegalNotice.sentence(for: step)
            XCTAssertTrue(text.contains("you agree to the Terms of Service"), text)
            XCTAssertTrue(text.contains("Privacy Policy"), text)
        }
        XCTAssertTrue(LegalNotice.sentence(for: .createAccount).hasPrefix("By creating an account"))
        XCTAssertTrue(LegalNotice.sentence(for: .createShop).hasPrefix("By creating a shop"))
    }

    // MARK: PaymentOutcomeSpeech

    func testPaymentAnnouncements() {
        XCTAssertEqual(PaymentOutcomeSpeech.announcement(for: .succeeded("Payment received")), "Payment succeeded.")
        XCTAssertEqual(
            PaymentOutcomeSpeech.announcement(for: .succeeded("Payment submitted — it shows on the invoice once Stripe confirms it.")),
            "Payment succeeded. Payment submitted — it shows on the invoice once Stripe confirms it."
        )
        XCTAssertEqual(
            PaymentOutcomeSpeech.announcement(for: .failed("The card was declined")),
            "Payment not completed. The card was declined."
        )
        XCTAssertEqual(PaymentOutcomeSpeech.announcement(for: .failed("  ")), "Payment not completed.")
        XCTAssertEqual(PaymentOutcomeSpeech.announcement(for: .canceled), "Payment canceled. Nothing was charged.")
    }
}
