import XCTest
@testable import DetailCore

final class ShopEntitlementTests: XCTestCase {

    private let chicago = ShopClock(timeZoneIdentifier: "America/Chicago", locale: Locale(identifier: "en_US_POSIX"))

    private func decode(_ json: String) throws -> ShopEntitlement {
        try JSONDecoder().decode(ShopEntitlement.self, from: Data(json.utf8))
    }

    private func utc(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            XCTFail("bad fixture \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    // MARK: - Decoding

    func testDecodesTheFullPayload() throws {
        let value = try decode("""
        {"billing_enabled": true, "state": "trialing", "reason": "trial",
         "plan_name": null, "trial_ends_at": "2026-10-12T15:04:05.123456+00:00",
         "current_period_end": null, "cancel_at_period_end": false,
         "max_members": 5, "members_used": 3, "can_write": true, "is_owner": true}
        """)
        XCTAssertTrue(value.billingEnabled)
        XCTAssertEqual(value.state, .trialing)
        XCTAssertEqual(value.rawState, "trialing")
        XCTAssertEqual(value.reason, "trial")
        XCTAssertNil(value.planName)
        XCTAssertEqual(value.trialEndsAt?.timeIntervalSince1970 ?? 0,
                       utc("2026-10-12T15:04:05Z").timeIntervalSince1970 + 0.123456, accuracy: 0.000_001)
        XCTAssertNil(value.currentPeriodEnd)
        XCTAssertFalse(value.cancelAtPeriodEnd)
        XCTAssertEqual(value.maxMembers, 5)
        XCTAssertEqual(value.membersUsed, 3)
        XCTAssertTrue(value.canWrite)
        XCTAssertTrue(value.isOwner)
    }

    func testBillingOffDecodesAsActiveAndShowsNothing() throws {
        let value = try decode("""
        {"billing_enabled": false, "state": "active", "reason": "billing_off",
         "plan_name": null, "trial_ends_at": null, "current_period_end": null,
         "cancel_at_period_end": false, "max_members": null, "members_used": 2,
         "can_write": true, "is_owner": false}
        """)
        XCTAssertFalse(value.billingEnabled)
        XCTAssertEqual(value.state, .active)
        XCTAssertNil(value.maxMembers)
        XCTAssertNil(value.notice)
    }

    func testEveryStateDecodes() throws {
        let states: [(String, ShopEntitlement.State)] = [
            ("active", .active), ("trialing", .trialing), ("past_due", .pastDue),
            ("lapsed", .lapsed), ("comped", .comped),
        ]
        for (raw, expected) in states {
            let value = try decode(#"{"billing_enabled": true, "state": "\#(raw)", "can_write": true}"#)
            XCTAssertEqual(value.state, expected, raw)
        }
    }

    func testUnknownStateAndMissingFieldsAreTolerated() throws {
        let value = try decode(#"{"state": "something_new"}"#)
        XCTAssertNil(value.state)
        XCTAssertEqual(value.rawState, "something_new")
        XCTAssertFalse(value.billingEnabled)
        XCTAssertTrue(value.canWrite)
        XCTAssertFalse(value.isOwner)
        XCTAssertFalse(value.cancelAtPeriodEnd)
        XCTAssertNil(value.notice)
    }

    func testMissingCanWriteFollowsTheState() throws {
        XCTAssertFalse(try decode(#"{"billing_enabled": true, "state": "lapsed"}"#).canWrite)
        XCTAssertTrue(try decode(#"{"billing_enabled": true, "state": "past_due"}"#).canWrite)
    }

    func testAnUnreadableTimestampIsNil() throws {
        let value = try decode(#"{"billing_enabled": true, "state": "trialing", "trial_ends_at": "soon", "is_owner": true}"#)
        XCTAssertNil(value.trialEndsAt)
        XCTAssertNil(value.notice, "no date, no trial line")
    }

    // MARK: - Timestamps

    func testParsesPostgresTimestampForms() {
        let base = utc("2026-10-12T15:04:05Z")
        let cases: [(String, TimeInterval)] = [
            ("2026-10-12T15:04:05+00:00", 0),
            ("2026-10-12T15:04:05Z", 0),
            ("2026-10-12T15:04:05", 0),
            ("2026-10-12 15:04:05+00", 0),
            ("2026-10-12T15:04:05.5+00:00", 0.5),
            ("2026-10-12T15:04:05.123456Z", 0.123456),
            ("2026-10-12T10:04:05-05:00", 0),
            ("2026-10-12T20:34:05+05:30", 0),
            ("2026-10-12T20:34:05+0530", 0),
            ("  2026-10-12T15:04:05Z  ", 0),
        ]
        for (text, extra) in cases {
            guard let parsed = ShopEntitlement.parseTimestamp(text) else {
                XCTFail("could not parse \(text)")
                continue
            }
            XCTAssertEqual(parsed.timeIntervalSince1970, base.timeIntervalSince1970 + extra, accuracy: 0.000_001, text)
        }
    }

    func testRejectsMalformedTimestamps() {
        for text in ["", "2026-10-12", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z",
                     "2026-10-12T25:00:00Z", "2026-10-12T15:04:05.Z", "2026-10-12T15:04:05+5",
                     "2026-10-12T15:04:05 UTC", "infinity"] {
            XCTAssertNil(ShopEntitlement.parseTimestamp(text), text)
        }
    }

    // MARK: - Notice rules

    private func entitlement(_ state: ShopEntitlement.State?, owner: Bool, canWrite: Bool = true,
                             trialEnds: Date? = nil, billing: Bool = true, reason: String? = nil) -> ShopEntitlement {
        ShopEntitlement(billingEnabled: billing, state: state, reason: reason, trialEndsAt: trialEnds,
                        canWrite: canWrite, isOwner: owner)
    }

    func testNoticeRules() {
        let end = utc("2026-10-12T15:00:00Z")
        let table: [(String, ShopEntitlement, ShopEntitlement.Notice?)] = [
            ("billing off", entitlement(.active, owner: true, billing: false), nil),
            ("billing off, even with odd flags", entitlement(.lapsed, owner: true, canWrite: false, billing: false), nil),
            ("active owner", entitlement(.active, owner: true), nil),
            ("comped owner", entitlement(.comped, owner: true), nil),
            ("trialing owner", entitlement(.trialing, owner: true, trialEnds: end), .trialEnds(end)),
            ("trialing owner without a date", entitlement(.trialing, owner: true), nil),
            ("trialing manager", entitlement(.trialing, owner: false, trialEnds: end), nil),
            ("past due owner", entitlement(.pastDue, owner: true), .paymentProblem),
            ("past due technician", entitlement(.pastDue, owner: false), nil),
            ("lapsed owner", entitlement(.lapsed, owner: true, canWrite: false), .paused),
            ("lapsed technician", entitlement(.lapsed, owner: false, canWrite: false), .paused),
            ("unknown state but writes paused", entitlement(nil, owner: false, canWrite: false), .paused),
            ("unknown state", entitlement(nil, owner: true), nil),
            ("trial ended owner", entitlement(.lapsed, owner: true, canWrite: false, reason: "trial_ended"), .trialEnded),
            ("trial ended technician", entitlement(.lapsed, owner: false, canWrite: false, reason: "trial_ended"), .trialEnded),
            ("second shop, trial already used (0120)",
             entitlement(.lapsed, owner: true, canWrite: false, reason: "no_subscription"), .noSubscription),
            ("canceled subscription", entitlement(.lapsed, owner: true, canWrite: false, reason: "canceled"), .paused),
            ("unpaid subscription", entitlement(.lapsed, owner: false, canWrite: false, reason: "unpaid"), .paused),
            ("billing off, lapsed reason ignored",
             entitlement(.lapsed, owner: true, canWrite: false, billing: false, reason: "no_subscription"), nil),
        ]
        for (name, value, expected) in table {
            XCTAssertEqual(value.notice, expected, name)
        }
    }

    func testNoticeWordingIsNeutral() {
        let chicagoEvening = utc("2026-10-13T03:30:00Z") // still Oct 12 in Chicago
        XCTAssertEqual(ShopEntitlement.Notice.trialEnds(chicagoEvening).text(clock: chicago),
                       "Trial ends Monday, October 12, 2026.")
        XCTAssertEqual(ShopEntitlement.Notice.paymentProblem.text(clock: chicago),
                       "There's a problem with this shop's subscription payment.")
        XCTAssertEqual(ShopEntitlement.Notice.paused.text(clock: chicago),
                       "This shop's subscription is inactive. Creating new jobs, quotes, invoices and customers is paused.")
        XCTAssertFalse(ShopEntitlement.Notice.trialEnds(chicagoEvening).isWarning)
        XCTAssertTrue(ShopEntitlement.Notice.paymentProblem.isWarning)
        XCTAssertTrue(ShopEntitlement.Notice.paused.isWarning)
        XCTAssertEqual(ShopEntitlement.Notice.trialEnded.text(clock: chicago),
                       "This shop's trial has ended. Creating new jobs, quotes, invoices and customers is paused.")
        XCTAssertEqual(ShopEntitlement.Notice.noSubscription.text(clock: chicago),
                       "This shop has no subscription or free trial. Creating new jobs, quotes, invoices and customers is paused.")
        XCTAssertTrue(ShopEntitlement.Notice.trialEnded.isWarning)
        XCTAssertTrue(ShopEntitlement.Notice.noSubscription.isWarning)
        // Nothing that sells: no amounts, no plan, no call to buy.
        for notice in [ShopEntitlement.Notice.trialEnds(chicagoEvening), .paymentProblem, .paused, .trialEnded, .noSubscription] {
            let text = notice.text(clock: chicago).lowercased()
            for word in ["$", "price", "plan", "upgrade", "subscribe", "buy", "purchase", "renew", "settings"] {
                XCTAssertFalse(text.contains(word), "\(notice) mentions \(word)")
            }
        }
    }

    // MARK: - Right after creating a shop

    func testNewShopMessage() throws {
        let end = utc("2026-10-13T03:30:00Z") // Oct 12 in Chicago
        func message(_ value: ShopEntitlement?) -> ShopEntitlement.NewShopMessage {
            ShopEntitlement.newShopMessage(shopName: "Summit Auto Spa", entitlement: value, clock: chicago)
        }
        let ready = ShopEntitlement.NewShopMessage(text: "Summit Auto Spa is ready.", isWarning: false)
        XCTAssertEqual(message(nil), ready, "standing unknown")
        XCTAssertEqual(message(entitlement(.active, owner: true, billing: false, reason: "billing_off")), ready)
        XCTAssertEqual(message(entitlement(.comped, owner: true, reason: "comped")), ready)
        XCTAssertEqual(message(entitlement(.trialing, owner: true, trialEnds: end, reason: "trial")),
                       .init(text: "Summit Auto Spa is ready. Trial ends Monday, October 12, 2026.", isWarning: false))
        XCTAssertEqual(message(entitlement(.trialing, owner: true, reason: "trial")), ready, "no date, no trial words")

        // 0120: the person already had a trial, so the new shop starts lapsed.
        let second = try decode("""
        {"billing_enabled": true, "state": "lapsed", "reason": "no_subscription",
         "plan_name": null, "trial_ends_at": null, "current_period_end": null,
         "cancel_at_period_end": false, "max_members": null, "members_used": 1,
         "can_write": false, "is_owner": true}
        """)
        let used = message(second)
        XCTAssertTrue(used.isWarning)
        XCTAssertEqual(used.text,
                       "Summit Auto Spa was created without a free trial, because a free trial is given once per person. Creating new jobs, quotes, invoices and customers is paused.")
        XCTAssertEqual(second.notice, .noSubscription, "the status line keeps the reason afterwards")

        let other = message(entitlement(.lapsed, owner: true, canWrite: false, reason: "unknown_status"))
        XCTAssertTrue(other.isWarning)
        XCTAssertEqual(other.text, "Summit Auto Spa was created. " + ShopEntitlement.pausedText)

        // Neutral wording only (App Store 3.1.1 / 3.1.3).
        for text in [used.text, other.text, message(entitlement(.trialing, owner: true, trialEnds: end)).text] {
            for word in ["$", "price", "plan", "upgrade", "subscribe", "buy", "purchase", "renew", "settings", "billing"] {
                XCTAssertFalse(text.lowercased().contains(word), "\(text) mentions \(word)")
            }
        }
    }

    // MARK: - 402 refusals

    func testPaymentRequiredMatching() {
        XCTAssertTrue(ShopEntitlement.PaymentRequired.matches(databaseCode: "PT402"))
        XCTAssertTrue(ShopEntitlement.PaymentRequired.matches(databaseCode: "pt402"))
        XCTAssertFalse(ShopEntitlement.PaymentRequired.matches(databaseCode: "PT429"))
        XCTAssertFalse(ShopEntitlement.PaymentRequired.matches(databaseCode: nil))
        XCTAssertTrue(ShopEntitlement.PaymentRequired.matches(httpStatus: 402))
        XCTAssertFalse(ShopEntitlement.PaymentRequired.matches(httpStatus: 403))
    }

    func testPaymentRequiredKeepsTheServerMessage() {
        XCTAssertEqual(ShopEntitlement.PaymentRequired.message(serverMessage: " Your plan allows 5 team members. "),
                       "Your plan allows 5 team members.")
        XCTAssertEqual(ShopEntitlement.PaymentRequired.message(serverMessage: nil), ShopEntitlement.pausedText)
        XCTAssertEqual(ShopEntitlement.PaymentRequired.message(serverMessage: "  "), ShopEntitlement.pausedText)
    }

    func testServerMessageFromBodies() {
        let postgrest = #"{"code":"PT402","details":null,"hint":null,"message":"This shop's subscription has ended."}"#
        XCTAssertEqual(ShopEntitlement.PaymentRequired.serverMessage(fromBody: Data(postgrest.utf8)),
                       "This shop's subscription has ended.")
        let envelope = #"{"error":"Paused.","code":"payment_required"}"#
        XCTAssertEqual(ShopEntitlement.PaymentRequired.serverMessage(fromBody: Data(envelope.utf8)), "Paused.")
        XCTAssertNil(ShopEntitlement.PaymentRequired.serverMessage(fromBody: Data("<html>".utf8)))
        XCTAssertNil(ShopEntitlement.PaymentRequired.serverMessage(fromBody: Data(#"{"message":""}"#.utf8)))
        XCTAssertNil(ShopEntitlement.PaymentRequired.serverMessage(fromBody: Data("[1]".utf8)))
    }
}
