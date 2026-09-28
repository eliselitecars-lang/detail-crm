//
//  MoneyTerminalTokenProvider.swift
//  DetailCRM
//
//  Connection tokens for the Stripe Terminal SDK (P-6). The SDK accepts one
//  token provider per app run, so this is a single object that asks the
//  `payments` edge function for a token of the shop being paid; the token
//  is created on that shop's connected Stripe account, which is how every
//  Terminal call lands on the shop's account. Switching shops clears the
//  SDK's cached credentials (MoneyTapToPayModel does that).
//
//  Only used when Config.plist turns in-person payments on.
//

import Foundation
import StripeTerminal

final class MoneyTerminalTokenProvider: NSObject, ConnectionTokenProvider {

    static let shared = MoneyTerminalTokenProvider()

    private let lock = NSLock()
    private var shopID: UUID?

    private override init() {
        super.init()
    }

    /// Gives the SDK its token provider (once per app run; the SDK refuses a
    /// second one). Call before touching `Terminal.shared`.
    static func install() {
        if !Terminal.hasTokenProvider() {
            Terminal.setTokenProvider(shared)
        }
    }

    /// Tokens are made for this shop from now on. Returns true when it is a
    /// different shop than before (the caller then clears the SDK's cached
    /// credentials and any reader connection).
    @discardableResult
    func use(shopID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = self.shopID != nil && self.shopID != shopID
        self.shopID = shopID
        return changed
    }

    private var currentShopID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return shopID
    }

    // MARK: ConnectionTokenProvider

    func fetchConnectionToken(_ completion: @escaping ConnectionTokenCompletionBlock) {
        guard let shopID = currentShopID else {
            completion(nil, Self.error("Choose a shop before taking an in-person payment."))
            return
        }
        Task {
            do {
                let token = try await MoneyTerminalService.connectionToken(shopID: shopID)
                completion(token.secret, nil)
            } catch {
                completion(nil, Self.error(ErrorText.message(for: error)))
            }
        }
    }

    /// An error the SDK passes back to the app with our wording.
    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "DetailCRM.TerminalConnectionToken",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
