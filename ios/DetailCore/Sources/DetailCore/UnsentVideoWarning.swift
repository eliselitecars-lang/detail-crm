import Foundation

/// The wording of the confirmations that can delete a job video that
/// hasn't finished uploading. The camera recorder doesn't save to Photos,
/// so until the upload finishes the app's copy is the only one: signing
/// out (which deletes every pending upload on this iPhone) and "Discard
/// this video" both say so and ask first.
public enum UnsentVideoWarning {

    /// Title, message and confirm button of a confirmation.
    public struct Prompt: Equatable, Sendable {
        public let title: String
        public let message: String
        public let confirmTitle: String

        public init(title: String, message: String, confirmTitle: String) {
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
        }
    }

    /// The plain sign-out confirmation (nothing would be lost).
    public static let plainSignOut = Prompt(
        title: "Sign out?",
        message: "You'll need your email and password to sign back in.",
        confirmTitle: "Sign out"
    )

    /// The sign-out confirmation for `videoCount` unsent videos on
    /// `jobCount` jobs (the signed-in user's pending uploads). No videos:
    /// the plain one.
    public static func signOut(videoCount: Int, jobCount: Int) -> Prompt {
        guard videoCount > 0 else { return plainSignOut }
        let jobs = max(1, min(jobCount, videoCount))
        let videos = videoCount == 1 ? "1 job video hasn't" : "\(videoCount) job videos haven't"
        let place = jobs == 1 ? "" : " on \(jobs) jobs"
        let them = videoCount == 1 ? "it" : "them"
        let job = jobs == 1 ? "that job" : "each job"
        return Prompt(
            title: videoCount == 1 ? "Delete 1 unsent video?" : "Delete \(videoCount) unsent videos?",
            message: "\(videos) finished uploading\(place). The only copy is in this app (the camera "
                + "doesn't save to Photos), and signing out deletes \(them) for good. To keep \(them), "
                + "tap Cancel, open \(job) while you have a connection and let the upload finish, or "
                + "use \"Save or share video\" in the paused upload's menu. You'll need your email and password to sign back in.",
            confirmTitle: videoCount == 1 ? "Sign out and delete video" : "Sign out and delete videos"
        )
    }

    /// The sentence the account-deletion confirmation adds while the user
    /// has unsent videos (deleting the account signs out, which deletes
    /// them); nil when there are none.
    public static func accountDeletionNote(videoCount: Int) -> String? {
        guard videoCount > 0 else { return nil }
        let videos = videoCount == 1
            ? "1 job video that hasn't finished uploading is"
            : "\(videoCount) job videos that haven't finished uploading are"
        return videos + " deleted from this iPhone too."
    }

    /// "Discard this video" on a paused upload.
    public static let discard = Prompt(
        title: "Discard this video?",
        message: "It hasn't been uploaded, and the only copy is in this app (the camera doesn't save "
            + "to Photos). Discarding deletes it for good. To keep it, use \"Save or share video\" first.",
        confirmTitle: "Discard video"
    )
}
