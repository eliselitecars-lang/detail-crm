//
//  NewJobModel.swift
//  DetailCRM
//
//  State for the New Job flow: customer → vehicle → services → schedule →
//  review. Prices come from `price_services` for the chosen customer and
//  vehicle (category price, membership inclusions, suggested member
//  discount); the review shows the server's preview totals.
//
//  Creating is three idempotent steps — job row, line items (one batch),
//  assignments (one batch). Each finished step is remembered, so Retry
//  after a partial failure continues where it stopped and never inserts a
//  second job.
//

import Foundation
import Observation
import DetailCore

enum NewJobStep: Int, CaseIterable, Identifiable {
    case customer
    case vehicle
    case services
    case schedule
    case review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .customer: return "Customer"
        case .vehicle: return "Vehicle"
        case .services: return "Services"
        case .schedule: return "Schedule"
        case .review: return "Review"
        }
    }
}

/// Minimal new-customer fields.
struct NewJobCustomerDraft: Hashable {
    var firstName = ""
    var lastName = ""
    var phone = ""
    var email = ""

    var hasName: Bool { firstName.trimmedNonEmpty != nil || lastName.trimmedNonEmpty != nil }
}

/// The catalog plus prices for the current customer/vehicle.
struct NewJobServicesData: Hashable {
    var catalog: JobCatalog
    var pricing: JobPricedCatalog
    /// Customer + vehicle + category the prices were computed for.
    var pricedFor: NewJobPricingKey
}

struct NewJobPricingKey: Hashable {
    var customerID: UUID?
    var vehicleID: UUID?
    var categoryID: UUID?
}

@Observable
@MainActor
final class NewJobModel {

    let prefillStart: Date?
    let prefillCustomerID: UUID?

    private(set) var shopID: UUID?
    private(set) var clock = ShopClock(timeZone: .current)
    private(set) var defaultLocation: JobLocationType = .shop

    var step: NewJobStep = .customer

    // Reference data
    private(set) var categories: [JobVehicleCategory] = []
    private(set) var team: [JobTeamMember] = []
    private(set) var resources: [JobResource] = []

    // Customer
    var customerQuery = ""
    var customerResults: LoadState<[JobCustomer]> = .loaded([])
    private(set) var customer: JobCustomer?
    var isAddingCustomer = false
    var customerDraft = NewJobCustomerDraft()
    var customerError: String?

    // Vehicle
    var vehicles: LoadState<[JobVehicle]> = .idle
    private(set) var vehicle: JobVehicle?
    var isAddingVehicle = false
    var vehicleDraft = JobVehicleDraft()
    var vehicleYearText = ""
    var vehicleError: String?
    /// Category used for pricing when the job has no vehicle.
    var pricingCategoryID: UUID?

    // Services
    var services: LoadState<NewJobServicesData> = .idle
    var selectedServiceIDs: Set<UUID> = []
    var applyMemberDiscount = true
    var reviewPricing: LoadState<JobPricing> = .idle

    // Schedule
    var scheduleLater = false
    var start = Date()
    var durationMinutes = 60
    private(set) var durationEdited = false
    var locationType: JobLocationType = .shop
    var addressLine1 = ""
    var addressLine2 = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var resourceID: UUID?
    var assigneeIDs: Set<UUID> = []
    var notes = ""
    var internalNotes = ""

    // Create
    private(set) var createdJob: Job?
    private(set) var linesInserted = false
    private(set) var assignmentsInserted = false
    private(set) var isCreating = false
    var createError: String?

    init(prefillStart: Date?, prefillCustomerID: UUID?) {
        self.prefillStart = prefillStart
        self.prefillCustomerID = prefillCustomerID
    }

    // MARK: - Setup

    func configure(shopID: UUID, clock: ShopClock, businessType: BusinessType?) {
        let firstTime = self.shopID == nil
        self.shopID = shopID
        self.clock = clock
        defaultLocation = businessType == .mobile ? .mobile : .shop
        guard firstTime else { return }
        locationType = defaultLocation
        if let prefillStart {
            start = prefillStart
        } else {
            let tomorrow = clock.addingDays(1, to: Date())
            start = clock.date(on: tomorrow, timeString: "09:00") ?? Date()
        }
    }

    private func requireShop() throws -> UUID {
        guard let shopID else { throw AppError.noShopSelected }
        return shopID
    }

    /// Categories, team and resources (best effort), and the prefilled customer.
    func loadReferenceData() async {
        guard let shopID else { return }
        async let categoriesTask = try? JobService.vehicleCategories(shopID: shopID)
        async let teamTask = try? JobService.team(shopID: shopID)
        async let resourcesTask = try? JobService.resources(shopID: shopID)
        categories = await categoriesTask ?? []
        team = (await teamTask ?? []).filter(\.active)
        resources = await resourcesTask ?? []
        if customer == nil, let prefillCustomerID {
            if let found = try? await JobService.customer(shopID: shopID, customerID: prefillCustomerID) {
                await selectCustomer(found)
            }
        }
    }

    // MARK: - Customer

    func searchCustomers() async {
        guard let shopID else { return }
        let term = customerQuery
        guard term.trimmedNonEmpty != nil else {
            customerResults = .loaded([])
            return
        }
        customerResults.beginLoading()
        let result = await LoadState<[JobCustomer]>.result {
            try await JobService.searchCustomers(shopID: shopID, term: term)
        }
        // A newer query may have started meanwhile.
        guard term == customerQuery else { return }
        customerResults.apply(result)
        if case .failed = result, customerResults.value != nil {
            customerResults = result
        }
    }

    func selectCustomer(_ selected: JobCustomer) async {
        let changed = customer?.id != selected.id
        customer = selected
        isAddingCustomer = false
        customerError = nil
        if changed {
            vehicle = nil
            vehicles = .idle
            isAddingVehicle = false
            vehicleDraft = JobVehicleDraft()
            vehicleYearText = ""
            reviewPricing = .idle
            if locationType == .mobile, addressLine1.isEmpty {
                useCustomerAddress()
            }
        }
        step = .vehicle
        await loadVehicles()
    }

    func createCustomer() async {
        customerError = nil
        do {
            let shopID = try requireShop()
            let created = try await JobService.createCustomer(
                shopID: shopID,
                firstName: customerDraft.firstName,
                lastName: customerDraft.lastName,
                phone: customerDraft.phone,
                email: customerDraft.email
            )
            customerDraft = NewJobCustomerDraft()
            await selectCustomer(created)
        } catch {
            customerError = ErrorText.message(for: error)
        }
    }

    // MARK: - Vehicle

    func loadVehicles() async {
        guard let shopID, let customerID = customer?.id else { return }
        vehicles.beginLoading()
        let result = await LoadState<[JobVehicle]>.result {
            try await JobService.vehicles(shopID: shopID, customerID: customerID)
        }
        vehicles.apply(result)
        if let list = result.value, list.isEmpty {
            isAddingVehicle = true
        }
    }

    func selectVehicle(_ selected: JobVehicle?) {
        vehicle = selected
        isAddingVehicle = false
        vehicleError = nil
        if let selected {
            pricingCategoryID = selected.categoryID
        }
        reviewPricing = .idle
        step = .services
    }

    func createVehicle() async {
        vehicleError = nil
        do {
            let shopID = try requireShop()
            guard let customerID = customer?.id else { throw AppError.invalidInput("Choose a customer first.") }
            var draft = vehicleDraft
            if let yearText = vehicleYearText.trimmedNonEmpty {
                guard let year = Int(yearText), year >= 1886, year <= 2100 else {
                    throw AppError.invalidInput("Enter a 4-digit year.")
                }
                draft.year = year
            } else {
                draft.year = nil
            }
            let vin = VIN.normalize(draft.vin)
            if !vin.isEmpty {
                guard vin.count >= 5, vin.count <= 17, vin.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII }) else {
                    throw AppError.invalidInput("A VIN uses 5 to 17 letters and numbers.")
                }
            }
            guard draft.isMeaningful else {
                throw AppError.invalidInput("Enter at least the year, make, model or VIN.")
            }
            let created = try await JobService.createVehicle(shopID: shopID, customerID: customerID, draft: draft)
            var list = vehicles.value ?? []
            list.insert(created, at: 0)
            vehicles = .loaded(list)
            vehicleDraft = JobVehicleDraft()
            vehicleYearText = ""
            selectVehicle(created)
        } catch {
            vehicleError = ErrorText.message(for: error)
        }
    }

    /// Validates the VIN (DetailCore) and fills year/make/model/trim from NHTSA vPIC.
    func decodeVIN() async {
        vehicleError = nil
        let vin = VIN.normalize(vehicleDraft.vin)
        let check = VIN.validate(vin)
        guard check == .valid else {
            vehicleError = check.message
            return
        }
        do {
            let decoded = try await NewJobVINLookup.decode(vin)
            vehicleDraft.vin = vin
            if let year = decoded.year { vehicleYearText = String(year) }
            if let make = decoded.make { vehicleDraft.make = make }
            if let model = decoded.model { vehicleDraft.model = model }
            if let trim = decoded.trim { vehicleDraft.trim = trim }
        } catch {
            vehicleError = ErrorText.message(for: error)
        }
    }

    // MARK: - Services

    var pricingKey: NewJobPricingKey {
        NewJobPricingKey(
            customerID: customer?.id,
            vehicleID: vehicle?.id,
            categoryID: vehicle?.categoryID ?? pricingCategoryID
        )
    }

    /// Loads the catalog (once) and prices it for the current customer and
    /// vehicle (again whenever those change).
    func loadServices() async {
        guard let shopID else { return }
        let key = pricingKey
        if let current = services.value, current.pricedFor == key { return }
        services.beginLoading()
        let existingCatalog = services.value?.catalog
        let result = await LoadState<NewJobServicesData>.result {
            let catalog: JobCatalog
            if let existingCatalog {
                catalog = existingCatalog
            } else {
                catalog = try await PricingService.catalog(shopID: shopID)
            }
            let pricing = try await PricingService.priceCatalog(
                shopID: shopID,
                catalog: catalog,
                customerID: key.customerID,
                vehicleCategoryID: key.vehicleID == nil ? key.categoryID : nil,
                vehicleID: key.vehicleID
            )
            return NewJobServicesData(catalog: catalog, pricing: pricing, pricedFor: key)
        }
        services.apply(result)
        if let data = result.value {
            let valid = Set(data.catalog.entries.map(\.id))
            selectedServiceIDs = selectedServiceIDs.intersection(valid)
        }
    }

    /// Selected ids in catalog order (services first, then add-ons).
    var orderedSelection: [UUID] {
        guard let catalog = services.value?.catalog else { return [] }
        return (catalog.primaryEntries + catalog.addons).map(\.id).filter { selectedServiceIDs.contains($0) }
    }

    /// Sum of the selected services' durations for this vehicle.
    var selectedDurationMinutes: Int {
        guard let data = services.value else { return 0 }
        return orderedSelection.reduce(0) { total, id in
            let priced = data.pricing.price(for: id)?.durationMinutes
            let fallback = data.catalog.entries.first(where: { $0.id == id })?.durationMinutes ?? 0
            return total + (priced ?? fallback)
        }
    }

    var suggestedDiscountBps: Int {
        services.value?.pricing.suggestedDiscountBps ?? 0
    }

    func continueFromServices() {
        if !durationEdited {
            durationMinutes = max(selectedDurationMinutes, 30)
        }
        reviewPricing = .idle
        step = .schedule
    }

    // MARK: - Schedule

    func setDuration(_ minutes: Int) {
        durationMinutes = min(max(minutes, 15), 31 * 24 * 60)
        durationEdited = true
    }

    var end: Date {
        start.addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    func useCustomerAddress() {
        guard let customer else { return }
        addressLine1 = customer.addressLine1 ?? ""
        addressLine2 = customer.addressLine2 ?? ""
        city = customer.city ?? ""
        region = customer.region ?? ""
        postalCode = customer.postalCode ?? ""
    }

    var serviceAddressSummary: String? {
        JobAddressFormatting.summary(line1: addressLine1, line2: addressLine2, city: city, region: region, postalCode: postalCode)
    }

    /// Problems that block continuing past the schedule step.
    var scheduleProblem: String? {
        if locationType == .mobile && addressLine1.trimmedNonEmpty == nil {
            return "Enter the service address for a mobile job."
        }
        if notes.count > 20_000 || internalNotes.count > 20_000 {
            return "Notes are limited to 20,000 characters."
        }
        return nil
    }

    func continueFromSchedule() {
        guard scheduleProblem == nil else { return }
        step = .review
    }

    // MARK: - Review

    /// The server's preview of the selected services (totals with member
    /// discount and tax, before anything is saved).
    func loadReviewPricing() async {
        guard let shopID else { return }
        let ids = orderedSelection
        guard !ids.isEmpty else {
            reviewPricing = .idle
            return
        }
        let key = pricingKey
        reviewPricing.beginLoading()
        let result = await LoadState<JobPricing>.result {
            try await PricingService.price(
                shopID: shopID,
                customerID: key.customerID,
                vehicleCategoryID: key.vehicleID == nil ? key.categoryID : nil,
                serviceIDs: ids,
                vehicleID: key.vehicleID
            )
        }
        reviewPricing.apply(result)
    }

    /// Loads the review preview once (Retry reloads it explicitly).
    func loadReviewPricingIfNeeded() async {
        guard reviewPricing.value == nil else { return }
        await loadReviewPricing()
    }

    // MARK: - Create

    var hasStartedCreating: Bool { createdJob != nil }

    /// Creates the job (or finishes a partially created one). Returns the
    /// job id when every step succeeded.
    func create() async -> UUID? {
        guard !isCreating else { return nil }
        createError = nil
        isCreating = true
        defer { isCreating = false }
        do {
            let shopID = try requireShop()
            guard let customer else { throw AppError.invalidInput("Choose a customer.") }
            // Build the lines first so an unpriced service stops us before
            // anything is inserted.
            var lineDrafts: [JobLineDraft] = []
            if !linesInserted {
                let ids = orderedSelection
                if !ids.isEmpty {
                    guard let pricing = services.value?.pricing else {
                        throw AppError.message("Prices aren't loaded. Go back to Services and try again.")
                    }
                    lineDrafts = try pricing.lineDrafts(for: ids, vehicleID: vehicle?.id, firstSort: 1)
                }
            }
            let job: Job
            if let createdJob {
                job = createdJob
            } else {
                let discountBps = applyMemberDiscount ? suggestedDiscountBps : 0
                let isMobile = locationType == .mobile
                let draft = JobCreateDraft(
                    customerID: customer.id,
                    vehicleID: vehicle?.id,
                    status: scheduleLater ? .requested : .scheduled,
                    scheduledStart: scheduleLater ? nil : start,
                    scheduledEnd: scheduleLater ? nil : end,
                    locationType: locationType,
                    serviceAddressLine1: isMobile ? addressLine1 : nil,
                    serviceAddressLine2: isMobile ? addressLine2 : nil,
                    serviceCity: isMobile ? city : nil,
                    serviceRegion: isMobile ? region : nil,
                    servicePostalCode: isMobile ? postalCode : nil,
                    resourceID: resourceID,
                    notes: notes,
                    internalNotes: internalNotes,
                    discountKind: discountBps > 0 ? .percent : .none,
                    discountValue: discountBps
                )
                job = try await JobService.createJob(shopID: shopID, draft: draft)
                createdJob = job
            }
            if !linesInserted {
                try await JobService.insertLines(shopID: shopID, jobID: job.id, lines: lineDrafts)
                linesInserted = true
            }
            if !assignmentsInserted {
                let members = assigneeIDs.sorted { $0.uuidString < $1.uuidString }
                try await JobService.insertAssignments(shopID: shopID, jobID: job.id, memberIDs: members)
                assignmentsInserted = true
            }
            return job.id
        } catch {
            let text = ErrorText.message(for: error)
            if let createdJob {
                createError = "Job #\(createdJob.number) was created, but not everything was saved: \(text) Tap Retry to finish."
            } else {
                createError = text
            }
            return nil
        }
    }
}
