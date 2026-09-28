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
import Supabase
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

/// The shop-local day range the availability check loaded.
struct NewJobAvailabilityKey: Hashable {
    var from: Date
    var to: Date
}

/// What's booked around the chosen time, plus the shop's hours.
struct NewJobAvailabilityData: Hashable {
    var key: NewJobAvailabilityKey
    var items: [JobBusyItem]
    var hours: [JobBusinessHours]
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
    private(set) var categoriesFailed = false
    private(set) var teamFailed = false
    private(set) var resourcesFailed = false
    private(set) var prefillCustomerFailed = false

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
    var start = Date() {
        didSet {
            // Keep a repeat rule anchored on the picked first visit.
            if repeatEnabled {
                repeatDraft.rule = repeatDraft.rule.movingStart(from: oldValue, to: start, calendar: clock.calendar)
            }
        }
    }
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
    /// Busy items + hours for the chosen day(s) (SPEC §7 "date/time with
    /// availability"). Advisory: overlaps are allowed by the server.
    var availability: LoadState<NewJobAvailabilityData> = .idle
    private var cachedHours: [JobBusinessHours]?

    // Repeat (P-1): managers create a recurring series instead of one job.
    var repeatEnabled = false {
        didSet {
            if repeatEnabled && !oldValue {
                repeatDraft.rule = JobsSeriesDraft.Rule.defaults(for: start, calendar: clock.calendar)
            }
            repeatPreview = .idle
        }
    }
    var repeatDraft = JobsSeriesDraft() {
        didSet { if repeatDraft != oldValue { repeatPreview = .idle } }
    }
    var repeatPreview: LoadState<[JobsSeriesOccurrence]> = .idle

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

    /// Categories, team and resources, and the prefilled customer. Each
    /// failure is remembered (`referenceProblem`) so the flow says what is
    /// missing and offers a retry, instead of silently hiding the Assign
    /// card, the bay picker or the size picker.
    func loadReferenceData() async {
        guard let shopID else { return }
        async let categoriesTask = JobService.vehicleCategories(shopID: shopID)
        async let teamTask = JobService.team(shopID: shopID)
        async let resourcesTask = JobService.resources(shopID: shopID)
        do {
            categories = try await categoriesTask
            categoriesFailed = false
        } catch {
            categoriesFailed = true
        }
        do {
            let rows = try await teamTask
            team = rows.filter(\.active)
            teamFailed = false
        } catch {
            teamFailed = true
        }
        do {
            resources = try await resourcesTask
            resourcesFailed = false
        } catch {
            resourcesFailed = true
        }
        if customer == nil, let prefillCustomerID {
            do {
                let found = try await JobService.customer(shopID: shopID, customerID: prefillCustomerID)
                prefillCustomerFailed = false
                if let found {
                    await selectCustomer(found)
                }
            } catch {
                prefillCustomerFailed = true
            }
        } else {
            prefillCustomerFailed = false
        }
    }

    /// What supporting data failed to load, as one sentence (nil when all loaded).
    var referenceProblem: String? {
        var missing: [String] = []
        if prefillCustomerFailed { missing.append("the customer") }
        if categoriesFailed { missing.append("vehicle size categories") }
        if teamFailed { missing.append("the team") }
        if resourcesFailed { missing.append("bays and vans") }
        guard !missing.isEmpty else { return nil }
        return "Couldn't load " + missing.joined(separator: ", ") + ". Check the connection and try again."
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

    /// Validates the VIN (DetailCore) and fills year/make/model/trim from
    /// NHTSA vPIC. A scanned VIN the user confirmed despite its check digit
    /// (vehicles built outside North America) skips that check.
    func decodeVIN(requireCheckDigit: Bool = true) async {
        vehicleError = nil
        let vin = VIN.normalize(vehicleDraft.vin)
        let check = VIN.validate(vin, requireCheckDigit: requireCheckDigit)
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

    // MARK: - Availability

    /// The day(s) the proposed time touches; nil when scheduling later.
    var availabilityKey: NewJobAvailabilityKey? {
        guard !scheduleLater else { return nil }
        let from = clock.startOfDay(start)
        let lastDay = clock.startOfDay(max(start, end.addingTimeInterval(-1)))
        return NewJobAvailabilityKey(from: from, to: clock.addingDays(1, to: lastDay))
    }

    /// Loads the calendar feed for the chosen day(s) and the shop's hours
    /// (once). Old data for another day is never shown while loading.
    func loadAvailability() async {
        guard let shopID, let key = availabilityKey else { return }
        if let current = availability.value, current.key == key { return }
        availability = .loading
        let knownHours = cachedHours
        let result = await LoadState<NewJobAvailabilityData>.result {
            let items = try await JobService.busyItems(shopID: shopID, from: key.from, to: key.to)
            let hours: [JobBusinessHours]
            if let knownHours {
                hours = knownHours
            } else {
                hours = try await JobService.businessHours(shopID: shopID)
            }
            return NewJobAvailabilityData(key: key, items: items, hours: hours)
        }
        // The user picked another day meanwhile, or the task was replaced.
        guard key == availabilityKey else { return }
        if case .idle = result { return }
        availability = result
        if let data = result.value {
            cachedHours = data.hours
        }
    }

    /// Loaded data for the current day(s) only.
    private var currentAvailability: NewJobAvailabilityData? {
        guard let data = availability.value, data.key == availabilityKey else { return nil }
        return data
    }

    /// What's already on the calendar for the chosen day(s).
    var availabilityDayItems: [JobBusyItem] {
        guard let data = currentAvailability else { return [] }
        return JobAvailability.dayItems(data.items, start: start, end: end, clock: clock)
    }

    /// Hours, blocked-time and bay / team double-booking warnings for the
    /// chosen time, bay / van and team.
    var availabilityWarnings: [String] {
        guard let data = currentAvailability else { return [] }
        var warnings: [String] = []
        if let problem = JobAvailability.hoursProblem(start: start, end: end, hours: data.hours, clock: clock) {
            warnings.append(problem)
        }
        let resourceList = resources
        let teamList = team
        warnings += JobAvailability.conflicts(
            start: start,
            end: end,
            items: data.items,
            resourceID: resourceID,
            assigneeIDs: assigneeIDs,
            clock: clock,
            resourceName: { id in resourceList.first(where: { $0.id == id })?.name },
            memberName: { id in teamList.first(where: { $0.memberID == id })?.displayName }
        )
        return warnings
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
        if let problem = repeatProblem {
            return problem
        }
        if notes.count > 20_000 || internalNotes.count > 20_000 {
            return "Notes are limited to 20,000 characters."
        }
        return nil
    }

    // MARK: - Repeat

    /// Whether this job is created as a recurring series.
    var createsSeries: Bool { repeatEnabled && !scheduleLater }

    /// Whether the member discount applies to what Create makes. A
    /// repeating job always gets it: `create_job_series` takes no discount
    /// choice and prices every visit it generates with the membership's
    /// suggested percent (0051), so the switch only decides a one-off job.
    var appliesMemberDiscount: Bool {
        MemberDiscountChoice.applies(switchOn: applyMemberDiscount, repeating: createsSeries)
    }

    /// The member discount can be switched off (a one-off job only).
    var memberDiscountIsOptional: Bool { MemberDiscountChoice.isOptional(repeating: createsSeries) }

    /// What stops a series from being created, if anything.
    var repeatProblem: String? {
        guard createsSeries else { return nil }
        if orderedSelection.isEmpty {
            return "Choose at least one service: every visit of a repeating job gets the same services."
        }
        if orderedSelection.count > 30 {
            return "A repeating job can have at most 30 services."
        }
        if !repeatDraft.rule.isValid {
            return "Pick at least one day of the week to repeat on."
        }
        if case .onDate(let until) = repeatDraft.end, clock.startOfDay(until) < clock.startOfDay(start) {
            return "The repeat end date is before the first visit."
        }
        if durationMinutes < 15 || durationMinutes > 44_640 {
            return "A repeating visit lasts between 15 minutes and 31 days."
        }
        return nil
    }

    /// The `p_series` JSON for create / preview.
    var seriesJSON: [String: AnyJSON] {
        let calendar = clock.calendar
        var json = repeatDraft.rule.json.merging(repeatDraft.endJSON(calendar: calendar)) { _, new in new }
        let isMobile = locationType == .mobile
        json["start_date"] = .string(JobsSeriesDraft.dayString(start, calendar: calendar))
        json["local_start"] = .string(JobsSeriesDraft.timeString(start, calendar: calendar))
        json["duration_minutes"] = .integer(durationMinutes)
        json["location_type"] = .string(locationType.rawValue)
        json["template_lines"] = .array(orderedSelection.map { id in
            AnyJSON.object(["service_id": .string(id.uuidString.lowercased()), "quantity": .integer(1)])
        })
        json["assignee_member_ids"] = .array(
            assigneeIDs.sorted { $0.uuidString < $1.uuidString }.map { AnyJSON.string($0.uuidString) }
        )
        if let customer { json["customer_id"] = .string(customer.id.uuidString) }
        if let vehicle { json["vehicle_id"] = .string(vehicle.id.uuidString) }
        if let resourceID { json["resource_id"] = .string(resourceID.uuidString) }
        if isMobile {
            json["service_address_line1"] = addressLine1.trimmedNonEmpty.map { AnyJSON.string($0) } ?? .null
            json["service_address_line2"] = addressLine2.trimmedNonEmpty.map { AnyJSON.string($0) } ?? .null
            json["service_city"] = city.trimmedNonEmpty.map { AnyJSON.string($0) } ?? .null
            json["service_region"] = region.trimmedNonEmpty.map { AnyJSON.string($0) } ?? .null
            json["service_postal_code"] = postalCode.trimmedNonEmpty.map { AnyJSON.string($0) } ?? .null
        }
        if let text = notes.trimmedNonEmpty { json["notes"] = .string(text) }
        if let text = internalNotes.trimmedNonEmpty { json["internal_notes"] = .string(text) }
        return json
    }

    /// The server's list of the first visits (nothing saved).
    func loadRepeatPreview() async {
        guard let shopID, createsSeries, repeatProblem == nil, customer != nil else {
            repeatPreview = .idle
            return
        }
        let series = seriesJSON
        repeatPreview.beginLoading()
        let result = await LoadState<[JobsSeriesOccurrence]>.result {
            try await JobsSeriesService.preview(shopID: shopID, series: series, count: 6)
        }
        repeatPreview.apply(result)
        if case .failed = result { repeatPreview = result }
    }

    /// Change key for the preview task (anything that moves the dates).
    var repeatPreviewKey: String {
        guard createsSeries else { return "off" }
        let calendar = clock.calendar
        return [
            JobsSeriesDraft.dayString(start, calendar: calendar),
            JobsSeriesDraft.timeString(start, calendar: calendar),
            String(durationMinutes),
            repeatDraft.rule.summary,
            String(describing: repeatDraft.end),
        ].joined(separator: "|")
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
    /// job id when every step succeeded. A repeating job is created in one
    /// server call (the series and its first visits) and returns the first
    /// visit.
    func create() async -> UUID? {
        guard !isCreating else { return nil }
        createError = nil
        isCreating = true
        defer { isCreating = false }
        if createsSeries && createdJob == nil {
            return await createSeries()
        }
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
                let discountBps = appliesMemberDiscount ? suggestedDiscountBps : 0
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

    /// One atomic call: nothing is left half-created when it fails.
    private func createSeries() async -> UUID? {
        do {
            let shopID = try requireShop()
            guard customer != nil else { throw AppError.invalidInput("Choose a customer.") }
            if let problem = repeatProblem { throw AppError.invalidInput(problem) }
            let created = try await JobsSeriesService.create(shopID: shopID, series: seriesJSON)
            guard let firstJobID = created.firstJobID else {
                throw AppError.message("The repeating job was saved, but no visit falls in the next months. Check the repeat rule on the web app.")
            }
            return firstJobID
        } catch {
            createError = ErrorText.message(for: error)
            return nil
        }
    }
}
