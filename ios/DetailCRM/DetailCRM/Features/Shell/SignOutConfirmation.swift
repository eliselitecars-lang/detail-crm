//
//  SignOutConfirmation.swift
//  DetailCRM
//
//  The one sign-out confirmation (More, the shop picker, the launch error
//  screen). A deliberate sign-out deletes every pending job video upload
//  on this iPhone (AppState.performSignOut), and the camera recorder never
//  saves to Photos, so while the signed-in user has unsent videos the
//  dialog says how many and that signing out deletes them
//  (DetailCore `UnsentVideoWarning`).
//

import SwiftUI
import DetailCore

extension ConfirmationRequest {
    @MainActor
    static func signOut(_ appState: AppState) -> ConfirmationRequest {
        let pending = JobsResumableUploader.pending(userID: appState.userID)
        let prompt = UnsentVideoWarning.signOut(
            videoCount: pending.count,
            jobCount: Set(pending.map(\.jobID)).count
        )
        return ConfirmationRequest(
            title: prompt.title,
            message: prompt.message,
            confirmTitle: prompt.confirmTitle,
            isDestructive: true
        ) {
            await appState.signOut()
        }
    }
}
