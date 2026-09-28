import Foundation

/// What VoiceOver hears for a toast, and how long the banner stays when
/// VoiceOver is on. The app reports most outcomes (saved, deleted, a
/// server refusal, a failed refresh) with a toast, so it is announced as
/// well as shown: the banner alone fades away before a VoiceOver user can
/// reach it.
public enum ToastSpeech {

    /// The announcement text: errors say so first, since the banner's
    /// colour and icon aren't spoken.
    public static func announcement(message: String, isError: Bool) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isError else { return text }
        guard !text.isEmpty else { return "Error." }
        return "Error: " + text
    }

    /// With VoiceOver running the banner stays long enough to swipe to it
    /// (at least 10 s, errors 15 s); otherwise the requested duration.
    public static func visibleDuration(requested: Duration, isError: Bool, voiceOverRunning: Bool) -> Duration {
        guard voiceOverRunning else { return requested }
        let floor: Duration = isError ? .seconds(15) : .seconds(10)
        return max(requested, floor)
    }

    /// Delay before announcing, so the announcement isn't cut off by the
    /// screen change of a sheet that closes right after showing the toast.
    public static let announcementDelay: Duration = .milliseconds(600)
}
