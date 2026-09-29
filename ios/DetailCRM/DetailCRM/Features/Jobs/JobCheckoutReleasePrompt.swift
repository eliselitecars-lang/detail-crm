//
//  JobCheckoutReleasePrompt.swift
//  DetailCRM
//
//  0118: lowering a job's total or deposit (line edits and removals, the
//  discount, the deposit) is refused while a deposit payment page of the
//  job can still be paid (55000 HINT `checkout_open`). The job screens ask
//  before releasing that page, since the customer may be paying on it right
//  now. After the release the change is saved again only when no payment
//  went through or is still processing; otherwise it stops and says what
//  came in (the web's job edit toast does the same).
//

import Foundation
import DetailCore

extension JobDetailModel {

    /// The "cancel open payments?" question for a refused job edit, or nil
    /// for any other error (and for members who may not release payments):
    /// show those as usual. Confirming releases the job's open payments,
    /// then runs `saveAgain` when nothing was paid meanwhile (`onSaved`);
    /// when a payment came in, or on any failure, `onProblem` gets the text
    /// to show and the change is not saved.
    func checkoutReleaseRequest(
        for error: Error,
        saveAgain: @escaping () async throws -> Void,
        onSaved: @escaping () -> Void,
        onProblem: @escaping (String) -> Void
    ) -> ConfirmationRequest? {
        guard offersCheckoutRelease(for: error) else { return nil }
        let refusal = ErrorText.message(for: error)
        return ConfirmationRequest(
            title: "A payment page for this job is still open",
            message: refusal + "\n\n" + Self.checkoutReleaseExplanation,
            confirmTitle: "Cancel open payments",
            isDestructive: true
        ) { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.releaseOpenCheckoutThenSave(saveAgain)
                switch outcome {
                case .saved:
                    onSaved()
                case .notSaved(let release):
                    let summary = OpenCheckoutRefusal.releaseSummary(release)
                    onProblem(summary.title + ". " + summary.message)
                }
            } catch {
                onProblem(ErrorText.message(for: error))
            }
        }
    }

    static let checkoutReleaseExplanation =
        "Cancelling closes the customer's payment page, so it can't be paid until you send a new one. "
        + "If a payment already went through, it's recorded and your change isn't saved."
}
