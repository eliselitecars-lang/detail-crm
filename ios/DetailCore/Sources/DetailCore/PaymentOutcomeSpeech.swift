//
//  PaymentOutcomeSpeech.swift
//  DetailCore
//
//  What VoiceOver says when an in-person card payment (Tap to Pay on
//  iPhone, Bluetooth reader) ends. The result is otherwise only a changed
//  line of text and an icon on the progress sheet, and focus is somewhere
//  else when Apple's card-read screen closes: an operator using VoiceOver
//  must hear at once whether to hand the phone back or try again.
//

import Foundation

public enum PaymentOutcomeSpeech {

    public enum Outcome: Equatable, Sendable {
        /// The payment went through (or was submitted); the model's text.
        case succeeded(String)
        /// Declined or failed; the model's text says why.
        case failed(String)
        case canceled
    }

    /// The announcement: the result first, then the detail.
    public static func announcement(for outcome: Outcome) -> String {
        switch outcome {
        case .succeeded(let text):
            return join("Payment succeeded.", text)
        case .failed(let text):
            return join("Payment not completed.", text)
        case .canceled:
            return "Payment canceled. Nothing was charged."
        }
    }

    /// Delay before announcing, so the closing card-read screen doesn't
    /// cut the announcement off.
    public static let announcementDelay: Duration = .milliseconds(700)

    private static func join(_ lead: String, _ detail: String) -> String {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return lead }
        // "Payment succeeded. Payment received" says the same thing twice.
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "payment received" { return lead }
        let sentence = text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") ? text : text + "."
        return lead + " " + sentence
    }
}
