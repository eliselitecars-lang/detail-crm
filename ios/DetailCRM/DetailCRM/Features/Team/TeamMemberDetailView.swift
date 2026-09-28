//
//  TeamMemberDetailView.swift
//  DetailCRM
//
//  One member: contact (managers+), role change and (de)activation
//  (owners/admins, never the owner or yourself), Make owner (the owner
//  hands the shop to another active member, `transfer_ownership`), and pay settings
//  (owners/admins edit; a member reads their own). The server enforces
//  the same rules and its message is shown when it refuses. On your own
//  row every role (technicians included) can open "Your account" to edit
//  their name, phone and the name the team sees.
//

import SwiftUI
import DetailCore

struct TeamMemberDetailView: View {
    let onChanged: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var member: TeamDirectoryEntry
    @State private var pay: LoadState<MemberCompensation?> = .idle
    @State private var confirmation: ConfirmationRequest?
    @State private var showPayEditor = false

    init(member: TeamDirectoryEntry, onChanged: @escaping () async -> Void) {
        self.onChanged = onChanged
        _member = State(initialValue: member)
    }

    private var actorRole: ShopRole { appState.role ?? .technician }
    private var isSelf: Bool { member.memberID == appState.member?.id }
    private var canSeePay: Bool { appState.can(.viewAllCompensation) || isSelf }
    private var canEditPay: Bool { appState.can(.editCompensation) }
    /// Only the owner can hand the shop to another active member
    /// (`transfer_ownership`; the server enforces the same rule).
    private var canMakeOwner: Bool {
        actorRole == .owner && !isSelf && member.active && member.role != .owner
    }

    var body: some View {
        List {
            Section {
                TeamMemberHeader(member: member, isSelf: isSelf)
                    .themedRow()
            }
            if isSelf {
                Section {
                    NavigationLink {
                        SettingsAccountView()
                    } label: {
                        SettingsNavRow(title: "Your account", subtitle: "Name, phone and the name your team sees", systemImage: "person.crop.circle")
                    }
                    .themedRow()
                }
            }
            if appState.can(.viewTeamDetails) {
                TeamMemberContactSection(member: member)
            }
            if appState.can(.manageTeam) {
                TeamMemberAccessSection(
                    member: member,
                    assignableRoles: TeamPermissions.assignableRoles(actor: actorRole, target: member.role, isSelf: isSelf),
                    canToggleActive: TeamPermissions.canToggleActive(actor: actorRole, target: member.role, isSelf: isSelf),
                    isSelf: isSelf,
                    canMakeOwner: canMakeOwner,
                    changeRole: { role in confirmRoleChange(to: role) },
                    toggleActive: { confirmToggleActive() },
                    makeOwner: { confirmMakeOwner() }
                )
            }
            if canSeePay {
                TeamMemberPaySection(
                    state: pay,
                    currencyCode: appState.currencyCode,
                    canEdit: canEditPay,
                    retry: { await loadPay() },
                    edit: { showPayEditor = true }
                )
            }
        }
        .listStyle(.insetGrouped)
        .screenBackground()
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmation($confirmation)
        .sheet(isPresented: $showPayEditor) {
            TeamPayEditor(member: member, current: pay.value ?? nil, currencyCode: appState.currencyCode) { saved in
                pay = .loaded(saved)
            }
        }
        .task {
            if canSeePay { await loadPay() }
        }
        .onChange(of: appState.member?.displayName) { _, newName in
            // "Your account" saved a new team name: reflect it here and in the list.
            guard isSelf, let newName, newName != member.displayName else { return }
            member.displayName = newName
            Task { await onChanged() }
        }
    }

    private func loadPay() async {
        guard let shopID = appState.shop?.id else { return }
        let memberID = member.memberID
        pay.beginLoading()
        let result = await LoadState<MemberCompensation?>.result {
            try await TeamService.compensation(shopID: shopID, memberID: memberID)
        }
        pay.apply(result)
    }

    private func confirmRoleChange(to role: ShopRole) {
        let name = member.displayName
        confirmation = ConfirmationRequest(
            title: "Make \(name) \(role.displayName.lowercased() == "admin" ? "an" : "a") \(role.displayName)?",
            message: roleMessage(role),
            confirmTitle: "Change role"
        ) {
            do {
                let shopID = try appState.requireShopID()
                try await TeamService.changeRole(shopID: shopID, memberID: member.memberID, to: role)
                member.role = role
                toasts.show("\(name) is now \(role.displayName.lowercased() == "admin" ? "an" : "a") \(role.displayName).")
                await onChanged()
            } catch {
                toasts.showError(error)
            }
        }
    }

    private func roleMessage(_ role: ShopRole) -> String {
        switch role {
        case .admin: return "Admins can change settings, manage the team and see pay."
        case .manager: return "Managers run jobs, customers and money, but can't change settings or pay."
        case .technician: return "Technicians see only their assigned jobs."
        case .owner: return ""
        }
    }

    private func confirmMakeOwner() {
        let name = member.displayName
        let shopName = appState.shop?.name ?? "this shop"
        confirmation = ConfirmationRequest(
            title: "Make \(name) the owner?",
            message: "\(name) becomes the owner of \(shopName), with full control including billing and deleting the shop. You become an admin. Only the new owner can undo this.",
            confirmTitle: "Make owner",
            isDestructive: true
        ) {
            do {
                let shopID = try appState.requireShopID()
                try await TeamService.transferOwnership(shopID: shopID, memberID: member.memberID)
                member.role = .owner
                toasts.show("\(name) is now the owner. You're an admin.")
                // Your own role changed: the app re-reads it, so screens
                // follow what an admin may do.
                try? await appState.refreshCurrentShop()
                await onChanged()
            } catch {
                toasts.showError(error)
            }
        }
    }

    private func confirmToggleActive() {
        let name = member.displayName
        let activate = !member.active
        confirmation = ConfirmationRequest(
            title: activate ? "Reactivate \(name)?" : "Deactivate \(name)?",
            message: activate
                ? "\(name) will be able to sign in to this shop again."
                : "\(name) loses access to this shop right away. Their history (jobs, time) is kept.",
            confirmTitle: activate ? "Reactivate" : "Deactivate",
            isDestructive: !activate
        ) {
            do {
                let shopID = try appState.requireShopID()
                try await TeamService.setActive(shopID: shopID, memberID: member.memberID, active: activate)
                member.active = activate
                toasts.show(activate ? "\(name) was reactivated." : "\(name) was deactivated.")
                await onChanged()
            } catch {
                toasts.showError(error)
            }
        }
    }
}

private struct TeamMemberHeader: View {
    let member: TeamDirectoryEntry
    let isSelf: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: member.displayName, size: Theme.Size.avatarLarge, colorHex: member.calendarColor)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(isSelf ? "\(member.displayName) (you)" : member.displayName)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: Theme.Spacing.xs) {
                    StatusBadge(member.role)
                    StatusBadge(text: member.active ? "Active" : "Inactive", tone: member.active ? .success : .neutral)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct TeamMemberContactSection: View {
    let member: TeamDirectoryEntry
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section("Contact") {
            if let email = member.email, !email.isEmpty {
                contactRow(title: email, systemImage: "envelope", url: ContactLinks.email(email), hint: "Email \(member.displayName)")
            }
            if let phone = member.phone, !phone.isEmpty {
                contactRow(title: PhoneNumber.format(phone), systemImage: "phone", url: ContactLinks.call(phone), hint: "Call \(member.displayName)")
            }
            if (member.email ?? "").isEmpty && (member.phone ?? "").isEmpty {
                Text("No contact details.")
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
            }
        }
    }

    private func contactRow(title: String, systemImage: String, url: URL?, hint: String) -> some View {
        Button {
            if let url { openURL(url) }
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(url == nil ? Theme.textPrimary : Theme.glacier)
        }
        .disabled(url == nil)
        .accessibilityHint(hint)
        .themedRow()
    }
}

private struct TeamMemberAccessSection: View {
    let member: TeamDirectoryEntry
    let assignableRoles: [ShopRole]
    let canToggleActive: Bool
    let isSelf: Bool
    let canMakeOwner: Bool
    let changeRole: (ShopRole) -> Void
    let toggleActive: () -> Void
    let makeOwner: () -> Void

    var body: some View {
        Section {
            if assignableRoles.isEmpty {
                InfoRow(label: "Role", value: member.role.displayName)
                    .themedRow()
            } else {
                Menu {
                    ForEach(assignableRoles, id: \.self) { role in
                        Button(role.displayName) {
                            changeRole(role)
                        }
                    }
                } label: {
                    HStack {
                        Text("Role")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(member.role.displayName)
                            .foregroundStyle(Theme.glacier)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.glacier)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Role: \(member.role.displayName). Change role")
                .themedRow()
            }
            if canMakeOwner {
                Button(role: .destructive, action: makeOwner) {
                    Text("Make owner…")
                        .foregroundStyle(Theme.dangerInk)
                }
                .accessibilityHint("Hands the shop to this member. You become an admin.")
                .themedRow()
            }
            if canToggleActive {
                Button(role: member.active ? .destructive : nil) {
                    toggleActive()
                } label: {
                    Text(member.active ? "Deactivate member" : "Reactivate member")
                        .foregroundStyle(member.active ? Theme.dangerInk : Theme.glacier)
                }
                .themedRow()
            }
        } header: {
            Text("Access")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        if isSelf { return "You can't change your own role or deactivate yourself." }
        if member.role == .owner { return "The owner's role changes only when the owner makes someone else the owner." }
        if canMakeOwner { return "Only owners and admins can change roles. Make owner hands the shop to this member; you become an admin." }
        return "Only owners and admins can change roles. Only the owner can make someone else the owner."
    }
}

private struct TeamMemberPaySection: View {
    let state: LoadState<MemberCompensation?>
    let currencyCode: String
    let canEdit: Bool
    let retry: () async -> Void
    let edit: () -> Void

    var body: some View {
        Section {
            switch state {
            case .idle, .loading:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                    Text("Loading pay…")
                        .foregroundStyle(Theme.textSecondary)
                }
                .themedRow()
            case .failed(let message):
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    InlineMessage(text: message, kind: .error)
                    AsyncButton("Try again", style: .themeSecondaryCompact) {
                        await retry()
                    }
                }
                .themedRow()
            case .loaded(let compensation):
                if let compensation {
                    HStack {
                        Text("Hourly rate")
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        MoneyText(cents: compensation.hourlyRateCents, currencyCode: currencyCode)
                    }
                    .accessibilityElement(children: .combine)
                    .themedRow()
                    InfoRow(label: "Commission", value: ShopSettingsPercent.display(compensation.commissionBps))
                        .themedRow()
                } else {
                    Text("No pay settings yet.")
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                }
                if canEdit {
                    Button("Edit pay") { edit() }
                        .foregroundStyle(Theme.glacier)
                        .themedRow()
                }
            }
        } header: {
            Text("Pay")
        } footer: {
            Text(canEdit ? "Commission is a percentage of each completed job's revenue before tax." : "Only owners and admins can change pay.")
        }
    }
}

/// Owner/admin sheet for hourly rate and commission.
private struct TeamPayEditor: View {
    let member: TeamDirectoryEntry
    let current: MemberCompensation?
    let currencyCode: String
    let onSaved: (MemberCompensation) -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var rateText: String
    @State private var commissionText: String
    @State private var errorMessage: String?

    init(member: TeamDirectoryEntry, current: MemberCompensation?, currencyCode: String, onSaved: @escaping (MemberCompensation) -> Void) {
        self.member = member
        self.current = current
        self.currencyCode = currencyCode
        self.onSaved = onSaved
        _rateText = State(initialValue: current.map { Money.editableString(cents: $0.hourlyRateCents, currencyCode: currencyCode) } ?? "")
        _commissionText = State(initialValue: current.map { ShopSettingsPercent.text(fromBasisPoints: $0.commissionBps) } ?? "")
    }

    private var rateCents: Int? {
        rateText.trimmedNonEmpty == nil ? 0 : Money.parseCents(rateText, currencyCode: currencyCode)
    }

    private var commissionBps: Int? {
        commissionText.trimmedNonEmpty == nil ? 0 : ShopSettingsPercent.basisPoints(from: commissionText)
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                Text("Pay for \(member.displayName)")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                ThemedTextField(
                    label: "Hourly rate",
                    placeholder: "0.00",
                    text: $rateText,
                    kind: .money,
                    hint: "Leave empty for no hourly pay.",
                    error: rateCents == nil ? "Enter an amount like 22.50." : nil
                )
                ThemedTextField(
                    label: "Commission (%)",
                    placeholder: "0",
                    text: $commissionText,
                    kind: .money,
                    hint: "Share of completed-job revenue before tax, 0–100 with up to 2 decimals.",
                    error: commissionBps == nil ? "Enter a percentage between 0 and 100." : nil
                )
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                AsyncButton("Save pay", style: .themePrimary) {
                    await save()
                }
                .disabled(rateCents == nil || commissionBps == nil)
            }
            .navigationTitle("Edit pay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        guard let cents = rateCents, let bps = commissionBps else { return }
        do {
            let shopID = try appState.requireShopID()
            let saved = try await TeamService.saveCompensation(
                MemberCompensation(shopID: shopID, memberID: member.memberID, hourlyRateCents: cents, commissionBps: bps)
            )
            onSaved(saved)
            toasts.show("Pay saved.")
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
