//
//  AppRoute.swift
//  DetailCRM
//
//  Cross-feature navigation. Any screen pushes a record with
//  `NavigationLink(value: AppRoute.job(id))`; every tab's NavigationStack
//  registers these destinations once (via `appRouteDestinations()`), so
//  features link to each other without editing shared files.
//
//  Contract for feature agents: the destination views below keep these
//  exact names and initializers (`JobDetailView(jobID:)`, …).
//

import SwiftUI

enum AppRoute: Hashable {
    case job(UUID)
    case customer(UUID)
    case quote(UUID)
    case invoice(UUID)
    /// A customer's inbox conversation (owner / admin / manager).
    case conversation(UUID)
}

struct AppRouteDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .job(let id):
            JobDetailView(jobID: id)
        case .customer(let id):
            CustomerDetailView(customerID: id)
        case .quote(let id):
            QuoteDetailView(quoteID: id)
        case .invoice(let id):
            InvoiceDetailView(invoiceID: id)
        case .conversation(let customerID):
            InboxThreadView(key: .customer(customerID))
        }
    }
}

extension View {
    /// Registers `AppRoute` destinations on the enclosing NavigationStack.
    func appRouteDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            AppRouteDestination(route: route)
        }
    }
}
