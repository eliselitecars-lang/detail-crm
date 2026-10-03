//
//  ScreenshotTests.swift
//  DetailCRMScreenshots (UI tests, CI only)
//
//  The screenshot tour behind .github/workflows/screenshots.yml. This file
//  is NOT part of the shipping project: ios/screenshots/add_ui_test_target.rb
//  adds a UI-test target for it at CI time. It lives outside the app's
//  synchronized folder (ios/DetailCRM/DetailCRM), so it is never compiled
//  into the app.
//
//  The tour signs in through the real Sign in screen against the workflow's
//  throwaway backend (sample data only), visits the main screens as the
//  owner, signs out, and repeats the field screens as the technician. Every
//  screen waits for its loading state to end before it is captured. A step
//  that fails is recorded (with a screenshot of what was on screen) and the
//  tour moves on, so one broken screen never loses the others.
//
//  Environment (xcodebuild passes TEST_RUNNER_<NAME> to the runner as <NAME>):
//    SHOTS_OWNER_EMAIL, SHOTS_OWNER_PASSWORD   required
//    SHOTS_TECH_EMAIL, SHOTS_TECH_PASSWORD     optional: without them the
//                                              technician part is skipped
//    SHOTS_DIR                                 optional host folder: every PNG
//                                              and report.txt are written there
//                                              too (besides the .xcresult)
//

import UIKit
import XCTest

final class ScreenshotTests: XCTestCase {

    @MainActor
    func testScreenshotTour() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let owner = ScreenshotTour.Credentials(env, prefix: "SHOTS_OWNER") else {
            XCTFail("SHOTS_OWNER_EMAIL / SHOTS_OWNER_PASSWORD are not set (pass TEST_RUNNER_SHOTS_OWNER_EMAIL / _PASSWORD)")
            return
        }
        let tour = ScreenshotTour(directory: env["SHOTS_DIR"])
        tour.launch()
        tour.ownerTour(owner)
        if let technician = ScreenshotTour.Credentials(env, prefix: "SHOTS_TECH") {
            tour.technicianTour(technician)
        } else {
            tour.skip("technician tour", reason: "SHOTS_TECH_EMAIL / SHOTS_TECH_PASSWORD are not set")
        }
        let report = tour.finish()
        add(attachmentNamed: "report", text: report)
        if !tour.signedIn {
            XCTFail("Could not sign in, so no app screens were captured.\n\(report)")
        }
    }

    private func add(attachmentNamed name: String, text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Drives the app and records what happened. Failures never stop the tour.
@MainActor
final class ScreenshotTour {

    struct Credentials {
        let email: String
        let password: String

        init?(_ env: [String: String], prefix: String) {
            guard let email = env[prefix + "_EMAIL"], !email.isEmpty,
                  let password = env[prefix + "_PASSWORD"], !password.isEmpty else { return nil }
            self.email = email
            self.password = password
        }
    }

    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let directory: URL?
    private var lines: [String] = []
    private var failures: [String] = []
    private var captured = 0
    private(set) var signedIn = false

    init(directory: String?) {
        if let directory, !directory.isEmpty {
            self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        } else {
            self.directory = nil
        }
    }

    func launch() {
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    // MARK: - Tours

    func ownerTour(_ owner: Credentials) {
        guard step("00-sign-in-owner", { signIn(owner, captureFormAs: "00-sign-in") }) else { return }
        signedIn = true

        step("01-owner-today") { openTab("Today") && scrollToTop() && shoot("01-owner-today", title: "Today") }
        step("02-owner-today-scrolled") { scrollPage() && shoot("02-owner-today-scrolled") }
        step("03-owner-job") {
            openTab("Today") && openTodayJob() && shoot("03-owner-job", expect: header("Customer & vehicle"))
        }
        step("04-owner-job-services") { scrollTo(header: "Services") && shoot("04-owner-job-services") }
        step("05-owner-job-checklist") { scrollTo(header: "Checklist") && shoot("05-owner-job-checklist") }
        step("06-owner-job-photos") { scrollTo(header: "Photos") && shoot("06-owner-job-photos") }

        step("07-owner-calendar-day") { openTab("Calendar") && shoot("07-owner-calendar-day", title: "Calendar") }
        step("08-owner-calendar-week") { pickSegment("Week") && shoot("08-owner-calendar-week") }
        step("09-owner-calendar-agenda") { pickSegment("Agenda") && shoot("09-owner-calendar-agenda") }

        step("10-owner-customers") { openTab("Customers") && shoot("10-owner-customers", title: "Customers") }
        step("11-owner-customer") { openFirstRow() && shoot("11-owner-customer") }
        step("12-owner-customer-scrolled") { scrollPage() && shoot("12-owner-customer-scrolled") }

        step("13-owner-inbox") { openTab("Inbox") && shoot("13-owner-inbox", title: "Inbox") }
        step("14-owner-inbox-thread") { openFirstRow() && shoot("14-owner-inbox-thread") }

        step("15-owner-more") { openTab("More") && shoot("15-owner-more", title: "More") }
        step("16-owner-quotes") { openMoreItem("Quotes") && shoot("16-owner-quotes", title: "Quotes") }
        step("17-owner-quote") { openFirstRow(preferring: "Sent") && shoot("17-owner-quote") }
        step("18-owner-invoices") { openMoreItem("Invoices") && shoot("18-owner-invoices", title: "Invoices") }
        step("19-owner-invoice") { openFirstRow(preferring: "Partially paid") && shoot("19-owner-invoice") }
        step("19b-owner-invoice-paid") {
            // A paid invoice's balance card shows the amount received.
            openMoreItem("Invoices") && openFirstRow(preferring: "Paid")
                && shoot("19b-owner-invoice-paid", expect: app.staticTexts["Paid in full"])
        }
        step("20-owner-payments") { openMoreItem("Payments") && shoot("20-owner-payments", title: "Payments") }
        step("21-owner-memberships") {
            openMoreItem("Memberships") && shoot("21-owner-memberships", title: "Memberships")
        }
        step("22-owner-time-clock") { openMoreItem("Time Clock") && shoot("22-owner-time-clock", title: "Time Clock") }
        step("23-owner-team-time") { openButton("Team time & timesheets") && shoot("23-owner-team-time", title: "Team time") }
        step("24-owner-tasks") { openMoreItem("Tasks") && shoot("24-owner-tasks", title: "Tasks") }
        step("25-owner-reports") { openMoreItem("Reports") && shoot("25-owner-reports", title: "Reports") }
        step("26-owner-reports-scrolled") { scrollPage() && shoot("26-owner-reports-scrolled") }
        step("27-owner-team") { openMoreItem("Team") && shoot("27-owner-team", title: "Team") }
        step("28-owner-catalog") { openMoreItem("Catalog") && shoot("28-owner-catalog", title: "Catalog") }
        step("29-owner-settings") { openMoreItem("Settings") && shoot("29-owner-settings", title: "Settings") }
        step("30-owner-notifications") {
            openMoreItem("Notifications") && shoot("30-owner-notifications", title: "Notifications")
        }
    }

    func technicianTour(_ technician: Credentials) {
        guard step("40-sign-in-technician", { signIn(technician, captureFormAs: nil) }) else { return }

        // The technician's screens are NOT reset first: a new sign-in must
        // start on fresh tabs (Today at the top, the Calendar in Day), even
        // though the owner left Today scrolled and the Calendar in Agenda.
        step("41-tech-today") {
            openTab("Today") && shoot("41-tech-today", title: "Today")
                && expectOnScreen(todayGreeting, "Today did not start at the top (the greeting is off screen)")
        }
        step("42-tech-today-scrolled") { scrollPage() && shoot("42-tech-today-scrolled") }
        step("43-tech-job") {
            openTab("Today") && openTodayJob() && shoot("43-tech-job", expect: header("Customer & vehicle"))
        }
        step("44-tech-job-checklist") { scrollTo(header: "Checklist") && shoot("44-tech-job-checklist") }
        step("45-tech-job-photos") { scrollTo(header: "Photos") && shoot("45-tech-job-photos") }
        step("46-tech-calendar-day") {
            openTab("Calendar") && shoot("46-tech-calendar-day", title: "Calendar")
                && expectOnScreen(selectedSegment("Day"), "the Calendar did not open in Day mode")
        }
        step("47-tech-calendar-agenda") { pickSegment("Agenda") && shoot("47-tech-calendar-agenda") }
        step("48-tech-time-clock") { openMoreItem("Time Clock") && shoot("48-tech-time-clock", title: "Time Clock") }
        step("49-tech-more") { openTab("More") && shoot("49-tech-more", title: "More") }
    }

    func skip(_ what: String, reason: String) {
        record("SKIPPED \(what): \(reason)")
    }

    /// The report (also written to SHOTS_DIR/report.txt and printed).
    func finish() -> String {
        let summary = failures.isEmpty
            ? "All steps passed; \(captured) screenshots."
            : "\(failures.count) step(s) failed: \(failures.joined(separator: ", ")); \(captured) screenshots."
        let report = (lines + [summary]).joined(separator: "\n") + "\n"
        print("==== screenshot tour ====\n" + report)
        if let directory {
            let file = directory.appendingPathComponent("report.txt")
            do {
                try report.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                print("could not write \(file.path): \(error)")
            }
        }
        return report
    }

    // MARK: - Steps

    /// Runs one step as an XCTest activity. A failed step is recorded with
    /// a screenshot of the screen it ended on; the tour carries on.
    @discardableResult
    private func step(_ name: String, _ body: () -> Bool) -> Bool {
        XCTContext.runActivity(named: name) { _ in
            dismissSystemAlerts(waiting: 0)
            dismissInAppPrompts()
            let ok = body()
            if ok {
                record("OK      \(name)")
            } else {
                failures.append(name)
                record("FAILED  \(name)")
                capture("fail-\(name)")
            }
            return ok
        }
    }

    private func record(_ line: String) {
        lines.append(line)
        print("[tour] \(line)")
    }

    /// Records why a step failed; always false so callers can `return note(...)`.
    @discardableResult
    private func note(_ message: String) -> Bool {
        record("        \(message)")
        return false
    }

    // MARK: - Sign in / out

    private func signIn(_ who: Credentials, captureFormAs formShot: String?) -> Bool {
        guard reachSignInScreen() else { return false }
        let email = app.textFields.firstMatch
        let password = app.secureTextFields.firstMatch
        guard email.waitForExistence(timeout: 10), password.exists else {
            return note("the Sign in fields were not found")
        }
        if let formShot {
            capture(formShot)
        }
        email.tap()
        dismissKeyboardTip()
        email.typeText(who.email)
        password.tap()
        dismissKeyboardTip()
        // Return ends editing, so the keyboard is gone before the tabs appear.
        password.typeText(who.password + "\n")
        let button = app.buttons["Sign in"]
        guard button.exists else { return note("no Sign in button") }
        button.tap()

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            dismissSystemAlerts(waiting: 0)
            if app.tabBars.firstMatch.exists {
                // Push permission is asked the first time the tabs appear.
                dismissSystemAlerts(waiting: 8)
                dismissInAppPrompts()
                return true
            }
            if app.staticTexts["Choose a shop"].exists || app.staticTexts["Let's get you set up"].exists {
                return note("signed in, but the account has no single shop to open (shop picker shown)")
            }
            pause(0.5)
        }
        return note("the main tabs did not appear within 60 s of tapping Sign in")
    }

    /// Waits for the Sign in screen; signs out first when a session is
    /// still active (the app keeps the session in the keychain).
    private func reachSignInScreen() -> Bool {
        let deadline = Date().addingTimeInterval(60)
        var signedOutOnce = false
        while Date() < deadline {
            dismissSystemAlerts(waiting: 0)
            if app.secureTextFields.firstMatch.exists && app.buttons["Sign in"].exists {
                return true
            }
            if app.staticTexts["Setup required"].exists {
                return note("the app shows Setup required: Config.plist has no backend URL / anon key")
            }
            if app.tabBars.firstMatch.exists && !signedOutOnce {
                signedOutOnce = true
                if !signOut() {
                    return note("a previous session is still signed in and Sign out failed")
                }
                continue
            }
            pause(0.5)
        }
        return note("the Sign in screen did not appear within 60 s")
    }

    private func signOut() -> Bool {
        guard openTab("More") else { return false }
        let button = app.buttons["Sign out"]
        guard reveal(button) else { return note("More › Sign out not found") }
        button.tap()
        let confirm = app.alerts.firstMatch.buttons["Sign out"]
        guard confirm.waitForExistence(timeout: 5) else { return note("the sign-out confirmation did not appear") }
        confirm.tap()
        guard app.secureTextFields.firstMatch.waitForExistence(timeout: 20) else {
            return note("the Sign in screen did not come back after signing out")
        }
        return true
    }

    // MARK: - Navigation

    /// Selects a tab and returns to its root screen.
    private func openTab(_ name: String) -> Bool {
        let tab = app.tabBars.buttons[name]
        guard tab.waitForExistence(timeout: 10) else { return note("there is no \"\(name)\" tab") }
        tab.tap()
        return popToRoot(name)
    }

    private func popToRoot(_ title: String) -> Bool {
        if app.navigationBars[title].waitForExistence(timeout: 2) { return true }
        for _ in 0..<6 {
            if app.navigationBars[title].exists { return true }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
            pause(0.8)
        }
        return app.navigationBars[title].waitForExistence(timeout: 5) || note("could not get back to \(title)")
    }

    private func openMoreItem(_ title: String) -> Bool {
        guard openTab("More") else { return false }
        return openButton(title)
    }

    private func openButton(_ label: String) -> Bool {
        let button = app.buttons[label]
        // A lazy list only creates rows near the screen: scroll when absent.
        _ = button.waitForExistence(timeout: 4)
        guard reveal(button) else { return note("\"\(label)\" not found on screen") }
        button.tap()
        return true
    }

    /// Today's in-progress job (the one with checklist progress), else Next
    /// Up's "Open job", else the first job row (row labels carry the status
    /// and the time range).
    private func openTodayJob() -> Bool {
        guard waitForLoading(timeout: 40) else { return note("Today is still loading") }
        let inProgress = app.scrollViews.firstMatch.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'In progress'")
        ).firstMatch
        if inProgress.exists, reveal(inProgress) {
            inProgress.tap()
            return true
        }
        let open = app.buttons["Open job"]
        if open.exists, reveal(open) {
            open.tap()
            return true
        }
        let rows = app.scrollViews.firstMatch.buttons.matching(
            NSPredicate(format: "label CONTAINS 'AM' OR label CONTAINS 'PM'")
        )
        let row = rows.firstMatch
        if row.exists, reveal(row) {
            row.tap()
            return true
        }
        return note("Today has no job to open (no Next Up card and no job rows)")
    }

    /// Taps the first row of the screen's list whose label contains
    /// `preferring` (e.g. a status), else its first navigation row.
    private func openFirstRow(preferring preferred: String? = nil) -> Bool {
        guard waitForLoading(timeout: 40) else { return note("the list is still loading") }
        let list = app.collectionViews.firstMatch
        guard list.waitForExistence(timeout: 10) else { return note("no list on screen (empty state?)") }
        if let preferred {
            let match = list.buttons.matching(NSPredicate(format: "label CONTAINS %@", preferred)).firstMatch
            if match.exists, reveal(match) {
                match.tap()
                return true
            }
        }
        let candidates = [list.buttons, list.cells]
        for query in candidates {
            let count = min(query.count, 8)
            for index in 0..<count {
                let row = query.element(boundBy: index)
                if row.exists && row.isHittable && !row.label.isEmpty {
                    row.tap()
                    return true
                }
            }
        }
        return note("the list has no row to open")
    }

    /// Today's "Good morning, …" line (at the top of the page).
    private var todayGreeting: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Good '")).firstMatch
    }

    /// The segment titled `title` when it is the selected one.
    private func selectedSegment(_ title: String) -> XCUIElement {
        app.segmentedControls.buttons.matching(NSPredicate(format: "label == %@ AND selected == true", title)).firstMatch
    }

    /// Records `problem` (failing the step) unless `element` is on screen.
    private func expectOnScreen(_ element: XCUIElement, _ problem: String) -> Bool {
        element.waitForExistence(timeout: 5) && element.isHittable ? true : note(problem)
    }

    private func pickSegment(_ title: String) -> Bool {
        let segment = app.segmentedControls.buttons[title]
        guard segment.waitForExistence(timeout: 10) else { return note("segment \"\(title)\" not found") }
        segment.tap()
        return true
    }

    // MARK: - Scrolling

    /// A section header (SectionHeader upper-cases its title).
    private func header(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", text)).firstMatch
    }

    /// Taps the status bar: the screen's scroll view returns to the top.
    private func scrollToTop() -> Bool {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 16))
            .tap()
        pause(1)
        return true
    }

    /// Scrolls the screen by about half a page.
    private func scrollPage() -> Bool {
        guard waitForLoading(timeout: 40) else { return note("still loading before scrolling") }
        drag(by: screenHeight * 0.5)
        return true
    }

    /// Scrolls until the section header sits near the top of the screen.
    private func scrollTo(header text: String) -> Bool {
        let element = header(text)
        guard element.waitForExistence(timeout: 10) || reveal(element) else {
            return note("section \"\(text)\" not found")
        }
        let target = app.frame.minY + screenHeight * 0.14
        var previous = CGFloat.greatestFiniteMagnitude
        for _ in 0..<10 {
            guard element.exists else { break }
            let top = element.frame.minY
            let delta = top - target
            if abs(delta) < 40 || abs(top - previous) < 2 { break }
            previous = top
            drag(by: max(-screenHeight * 0.5, min(screenHeight * 0.5, delta)))
        }
        return true
    }

    /// Scrolls (down, then back up) until the element is on screen.
    private func reveal(_ element: XCUIElement) -> Bool {
        if element.exists && element.isHittable { return true }
        for direction in [CGFloat(1), CGFloat(-1)] {
            for _ in 0..<7 {
                drag(by: direction * screenHeight * 0.4)
                if element.exists && element.isHittable { return true }
            }
        }
        return false
    }

    private var screenHeight: CGFloat {
        let height = app.frame.height
        return height > 0 ? height : 900
    }

    /// Positive distance moves the content up (shows what is below). The
    /// finger holds at the end so the scroll view does not fling, and runs
    /// down the right-hand margin, where no row or button can take the
    /// press (a drag that starts on a checklist row does not scroll).
    private func drag(by distance: CGFloat) {
        let startY: CGFloat = distance > 0 ? 0.72 : 0.28
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: startY))
        let end = start.withOffset(CGVector(dx: 0, dy: -distance))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        pause(0.4)
    }

    // MARK: - Capture

    /// Waits for the screen (optional title / element), for every loading
    /// state to end, then captures it. False when the screen did not
    /// appear, kept loading, or shows an error state (it is captured anyway).
    @discardableResult
    private func shoot(
        _ name: String,
        title: String? = nil,
        expect element: XCUIElement? = nil,
        timeout: TimeInterval = 40
    ) -> Bool {
        var ok = true
        if let title, !app.navigationBars[title].waitForExistence(timeout: timeout) {
            ok = note("the \"\(title)\" screen did not appear")
        }
        if let element, !element.waitForExistence(timeout: timeout) {
            ok = note("the expected content did not appear")
        }
        if !waitForLoading(timeout: timeout) {
            ok = note("still loading after \(Int(timeout)) s")
        }
        pause(1.2)
        dismissSystemAlerts(waiting: 0)
        retryOnceAfterNetworkError(timeout: timeout)
        let problem = app.staticTexts["Something went wrong"]
        if problem.exists {
            ok = note("the screen shows \"Something went wrong\"")
        }
        capture(name)
        return ok
    }

    /// The backend sits behind a quick tunnel that drops connections left
    /// idle for about a minute, so the first request after a quiet stretch
    /// (e.g. the Calendar right after the job screens) can fail with "the
    /// network connection was lost". Such a load is retried once with the
    /// screen's own Try again button, and the report says so; any other error
    /// (or a second failure) still fails the step.
    private func retryOnceAfterNetworkError(timeout: TimeInterval) {
        guard app.staticTexts["Something went wrong"].exists else { return }
        let networkError = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] 'offline' OR label CONTAINS[c] 'took too long' OR label CONTAINS[c] 'reach the server'"
        )).firstMatch
        let retry = app.buttons["Try again"]
        guard networkError.exists, retry.exists else { return }
        record("        (retried once after a network error: \"\(networkError.label)\")")
        retry.tap()
        pause(1)
        _ = waitForLoading(timeout: timeout)
        pause(1.2)
    }

    /// True once nothing on screen says "Loading…" (the app's LoadStateView
    /// and section loaders; the "Loading more…" paging row is ignored).
    private func waitForLoading(timeout: TimeInterval) -> Bool {
        let loading = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Loading' AND NOT (label CONTAINS 'Loading more')")
        ).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !loading.exists { return true }
            pause(0.5)
        }
        return false
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "screenshot \(name)") { activity in
            activity.add(attachment)
        }
        captured += 1
        guard let directory else { return }
        let file = directory.appendingPathComponent(name + ".png")
        do {
            try shot.pngRepresentation.write(to: file)
        } catch {
            print("could not write \(file.path): \(error)")
        }
    }

    // MARK: - System prompts

    /// Answers SpringBoard alerts (notifications, location, ...).
    private func dismissSystemAlerts(waiting seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        let choices = ["Allow", "Allow While Using App", "OK", "Continue", "Not Now", "Don’t Allow", "Don't Allow"]
        var answered = 0
        while answered < 6 {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                let label = choices.first { alert.buttons[$0].exists }
                if let label {
                    record("        (answered a system alert with \"\(label)\")")
                    alert.buttons[label].tap()
                } else if alert.buttons.count > 0 {
                    alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
                }
                answered += 1
                pause(1)
                continue
            }
            if Date() >= deadline { return }
            pause(0.5)
        }
    }

    /// In-app system sheets that can follow a sign-in (password saving).
    private func dismissInAppPrompts() {
        let notNow = app.buttons["Not Now"]
        if notNow.exists {
            notNow.tap()
            pause(0.5)
        }
    }

    /// The keyboard's one-time "slide to type" tip covers the keys.
    private func dismissKeyboardTip() {
        let tip = app.keyboards.buttons["Continue"]
        if tip.exists {
            tip.tap()
            pause(0.5)
        }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
