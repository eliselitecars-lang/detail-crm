//
//  CustomersView.swift
//  DetailCRM
//

import SwiftUI

// FEATURE_STUB: replaced by the Customers feature.
struct CustomersView: View {
    var body: some View {
        FeatureStubView(
            title: "Customers",
            systemImage: "person.2",
            summary: "Search customers, their vehicles and history."
        )
    }
}

// FEATURE_STUB: replaced by the Customers feature.
struct CustomerDetailView: View {
    let customerID: UUID

    var body: some View {
        FeatureStubView(
            title: "Customer",
            systemImage: "person.crop.circle",
            summary: "Contact details, vehicles, jobs, quotes, invoices and notes."
        )
    }
}
