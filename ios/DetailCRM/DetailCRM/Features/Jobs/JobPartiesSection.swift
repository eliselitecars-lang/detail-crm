//
//  JobPartiesSection.swift
//  DetailCRM
//
//  Customer and vehicle cards: call / text / email / directions, and a
//  link to the customer record for roles that can see all customers.
//

import SwiftUI
import DetailCore

struct JobPartiesSection: View {
    let job: Job
    let customer: JobCustomer?
    let vehicle: JobVehicle?
    let canOpenCustomer: Bool

    var body: some View {
        JobSectionCard("Customer & vehicle") {
            customerBlock
            JobDivider()
            vehicleBlock
        }
    }

    // MARK: - Customer

    @ViewBuilder
    private var customerBlock: some View {
        if let customer {
            JobCustomerBlock(
                customer: customer,
                serviceAddress: job.locationType == .mobile ? job.serviceAddressSummary : nil,
                canOpenCustomer: canOpenCustomer
            )
        } else {
            JobEmptyLine(text: "Customer details aren't available to you.", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    // MARK: - Vehicle

    @ViewBuilder
    private var vehicleBlock: some View {
        if let vehicle {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: "car.fill")
                    .foregroundStyle(Theme.glacier)
                    .frame(width: Theme.Size.rowIcon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(vehicle.label)
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    if let detail = vehicle.detailLine {
                        Text(detail)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let vin = vehicle.vin?.trimmedNonEmpty {
                        Text("VIN \(vin)")
                            .font(Theme.Typography.caption.monospaced())
                            .foregroundStyle(Theme.textTertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else {
            JobEmptyLine(text: "No vehicle on this job.", systemImage: "car")
        }
    }
}

/// Name, contact buttons and address of the job's customer.
struct JobCustomerBlock: View {
    let customer: JobCustomer
    /// Where the work happens (mobile jobs); falls back to the customer's address.
    let serviceAddress: String?
    let canOpenCustomer: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                AvatarView(name: customer.displayName, size: Theme.Size.avatarMedium)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(customer.displayName)
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    if let secondary = customer.secondaryLine {
                        Text(secondary)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let phone = customer.phoneDisplay {
                        Text(phone)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: Theme.Spacing.sm)
                if canOpenCustomer {
                    NavigationLink(value: AppRoute.customer(customer.id)) {
                        Image(systemName: "chevron.right.circle")
                            .font(Theme.Typography.title.weight(.regular))
                            .foregroundStyle(Theme.glacier)
                    }
                    .accessibilityLabel("Open customer")
                }
            }
            contactButtons
            if let address = serviceAddress ?? customer.addressSummary {
                addressRow(address, isServiceAddress: serviceAddress != nil)
            }
        }
    }

    private var contactButtons: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let phone = customer.phone, let callURL = ContactLinks.call(phone) {
                JobIconButton(systemImage: "phone.fill", accessibilityLabel: "Call \(customer.displayName)") {
                    openURL(callURL)
                }
            }
            if let phone = customer.phone, customer.smsOptedOutAt == nil, let textURL = ContactLinks.text(phone) {
                JobIconButton(systemImage: "message.fill", accessibilityLabel: "Text \(customer.displayName)") {
                    openURL(textURL)
                }
            }
            if let email = customer.email, let mailURL = ContactLinks.email(email) {
                JobIconButton(systemImage: "envelope.fill", accessibilityLabel: "Email \(customer.displayName)") {
                    openURL(mailURL)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func addressRow(_ address: String, isServiceAddress: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(isServiceAddress ? "Service address" : "Customer address")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                Text(address)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let mapsURL = MapLinks.directions(toAddress: address) {
                JobIconButton(systemImage: "arrow.triangle.turn.up.right.diamond.fill", accessibilityLabel: "Directions") {
                    openURL(mapsURL)
                }
            }
        }
    }
}
