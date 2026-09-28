//
//  OpsReferralService.swift
//  DetailCRM
//
//  Customer referral links (P-29, money 0069). When the shop's program is
//  on, a customer's link books with their personal code, which gives the
//  new customer the shop's referral discount; the referrer earns store
//  credit when that customer's first job is completed. Creating the code
//  (and its coupon) is owner / admin / manager only; the program itself is
//  set up in the web app.
//

import Foundation
import Supabase

enum OpsReferralService {

    /// The shop's program switch (`referral_settings`, managers+ read).
    // table: referral_settings
    struct Settings: Codable, Hashable, Sendable {
        var shopID: UUID
        var enabled: Bool

        enum CodingKeys: String, CodingKey {
            case shopID = "shop_id"
            case enabled
        }

        static let selectColumns = "shop_id,enabled"
    }

    /// `get_or_create_referral_code` result. `share_url` is null while the
    /// shop's web address isn't configured on the server.
    // rpc: get_or_create_referral_code
    struct Code: Codable, Hashable, Sendable {
        var code: String
        var shareURL: String?

        enum CodingKeys: String, CodingKey {
            case code
            case shareURL = "share_url"
        }

        /// The link as a URL, when it is a valid web address.
        var url: URL? {
            guard let shareURL, let components = URLComponents(string: shareURL),
                  let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  components.host?.isEmpty == false else { return nil }
            return components.url
        }
    }

    /// Whether the shop's referral program is on (false when there is no
    /// settings row or the caller can't read it).
    static func isProgramEnabled(shopID: UUID) async throws -> Bool {
        let rows: [Settings] = try await Supa.client
            .from("referral_settings")
            .select(Settings.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first?.enabled ?? false
    }

    /// The customer's code and share link, created on first use.
    static func code(customerID: UUID) async throws -> Code {
        struct Params: Encodable {
            let p_customer_id: UUID
        }
        do {
            return try await Supa.client
                .rpc("get_or_create_referral_code", params: Params(p_customer_id: customerID))
                .execute()
                .value
        } catch let error as PostgrestError where error.code == "55000" {
            throw AppError.message("The referral program is turned off. Turn it on in the web app's settings.")
        } catch let error as PostgrestError where error.code == "22023" {
            throw AppError.message(ErrorText.sentence(error.message))
        }
    }
}
