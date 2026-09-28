//
//  JobsSeriesScopeDialog.swift
//  DetailCRM
//
//  "Change this visit or the following ones too?" — asked before saving an
//  edit of a recurring visit (P-1). "This visit only" is a plain job update
//  (the server marks the visit as moved by hand, so later series edits
//  leave it alone); "This and following visits" goes through
//  `update_job_series` from this visit on. That RPC keeps every visit on
//  its own date and has no deposit, so an edit that moves the visit to
//  another day or changes its deposit is offered as "this visit only"
//  (`JobsSeriesDraft.followingScopeLimit`).
//

import SwiftUI

struct JobsSeriesScopeDialog: ViewModifier {
    @Binding var isPresented: Bool
    /// Set when the edit can't be carried to the following visits (a new
    /// date or deposit): only "this visit" is offered, with this reason.
    let followingLimit: String?
    let onThisVisit: () -> Void
    let onFollowing: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "This job repeats",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            if followingLimit == nil {
                Button("This visit only", action: onThisVisit)
                Button("This and following visits", action: onFollowing)
            } else {
                Button("Save this visit only", action: onThisVisit)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let followingLimit {
                Text(followingLimit)
            } else {
                Text("Following visits get the new time of day, length, place, bay or van and notes, and each keeps its own date. Later visits that are confirmed, paid, invoiced or were moved by hand keep their own details.")
            }
        }
    }
}

extension View {
    /// Asks whether an edit applies to this visit or to the following ones too.
    func jobsSeriesScopeDialog(
        isPresented: Binding<Bool>,
        followingLimit: String? = nil,
        onThisVisit: @escaping () -> Void,
        onFollowing: @escaping () -> Void
    ) -> some View {
        modifier(JobsSeriesScopeDialog(
            isPresented: isPresented,
            followingLimit: followingLimit,
            onThisVisit: onThisVisit,
            onFollowing: onFollowing
        ))
    }
}
