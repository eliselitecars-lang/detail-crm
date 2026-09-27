//
//  FeatureStubView.swift
//  DetailCRM
//
//  FEATURE_STUB: shared body for not-yet-built feature screens. Delete this
//  file once no feature stub references it (scripts/swift_sanity.py
//  --strict fails while any FEATURE_STUB marker remains).
//

import SwiftUI

struct FeatureStubView: View {
    let title: String
    let systemImage: String
    let summary: String

    var body: some View {
        EmptyStateView(systemImage: systemImage, title: title, message: summary)
            .screenBackground()
            .navigationTitle(title)
    }
}
