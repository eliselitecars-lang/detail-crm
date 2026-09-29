import Foundation

/// Where a received payment's money went, and what staff may still do
/// with it on the payments ledger (the web's `isUnappliedPayment`,
/// `canApplyToInvoice` and `refundableCents`, web/src/features/payments/
/// paymentFormat.ts).
///
/// An *unapplied* payment pays no invoice, job or membership: money the
/// server kept on the customer (a deposit whose job went away, an
/// overpayment moved off an invoice, …) with a note saying why. Managers
/// and above put it on one of the customer's open invoices
/// (`apply_payment_to_invoice`), or owners and admins refund it. The server
/// re-checks every rule; this only decides what the row shows and offers.
public enum PaymentApplication {

    /// What a ledger row's money is for.
    public enum Target: Hashable, Sendable {
        case invoice(UUID)
        case job(UUID)
        case membership(UUID)
        /// Pays nothing yet (see the type's note).
        case unapplied
    }

    /// The invoice wins over the job (an invoiced job's payments carry
    /// both), then the job, then the membership.
    public static func target(invoiceID: UUID?, jobID: UUID?, membershipID: UUID?) -> Target {
        if let invoiceID { return .invoice(invoiceID) }
        if let jobID { return .job(jobID) }
        if let membershipID { return .membership(membershipID) }
        return .unapplied
    }

    public static func isUnapplied(invoiceID: UUID?, jobID: UUID?, membershipID: UUID?) -> Bool {
        target(invoiceID: invoiceID, jobID: jobID, membershipID: membershipID) == .unapplied
    }

    /// What applying the payment puts toward an invoice: the amount less
    /// what was refunded of it. Tips never count toward an invoice
    /// (`payment_net_amount`), and refunds come off the amount first.
    public static func applicableCents(amountCents: Int, refundedCents: Int) -> Int {
        max(0, amountCents - min(max(0, refundedCents), max(0, amountCents)))
    }

    /// Whether staff may try to put the payment on an invoice: unapplied,
    /// received (succeeded or partly refunded) and with something left
    /// after refunds.
    public static func canApplyToInvoice(
        invoiceID: UUID?,
        jobID: UUID?,
        membershipID: UUID?,
        status: PaymentStatus,
        amountCents: Int,
        refundedCents: Int
    ) -> Bool {
        isUnapplied(invoiceID: invoiceID, jobID: jobID, membershipID: membershipID)
            && isReceived(status)
            && applicableCents(amountCents: amountCents, refundedCents: refundedCents) > 0
    }

    /// Amount plus tip not yet refunded, for received payments (0 for
    /// pending, processing, failed, cancelled or fully refunded ones).
    public static func refundableCents(status: PaymentStatus, amountCents: Int, tipCents: Int, refundedCents: Int) -> Int {
        guard isReceived(status) else { return 0 }
        return max(0, amountCents + tipCents - refundedCents)
    }

    public static func isReceived(_ status: PaymentStatus) -> Bool {
        status == .succeeded || status == .partiallyRefunded
    }
}
