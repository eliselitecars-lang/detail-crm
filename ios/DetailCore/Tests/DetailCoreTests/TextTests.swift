import XCTest
@testable import DetailCore

final class TemplateRendererTests: XCTestCase {

    func testReplacesKnownPlaceholders() {
        let out = TemplateRenderer.render(
            "Hi {{customer_first_name}}, see you {{ job_date }} at {{job_time}}.",
            values: ["customer_first_name": "Ana", "job_date": "Tue, Mar 10", "job_time": "9:30 AM"]
        )
        XCTAssertEqual(out, "Hi Ana, see you Tue, Mar 10 at 9:30 AM.")
    }

    /// Same inputs/outputs as the SQL `render_template` tests
    /// (supabase/tests/30_templates.sql) and the edge-function parity table
    /// (supabase/functions/_shared/templates_test.ts). Values are strings
    /// here because previews are rendered from already-formatted text.
    func testServerParityCases() {
        let cases: [(String, [String: String], String)] = [
            ("Hi {{customer_first_name}}!", ["customer_first_name": "Ana"], "Hi Ana!"),
            ("Hi {{ customer_first_name }}!", ["customer_first_name": "Ana"], "Hi Ana!"),
            ("Hi {{\tname\t}}", ["name": "Tab"], "Hi Tab"),
            ("{{ name }} {{\tname\t}} {{name  }}", ["name": "Al"], "Al Al Al"),
            ("Unknown: [{{nope}}]", [:], "Unknown: []"),
            ("{{a}}{{a}}{{b}}", ["a": "x", "b": "y"], "xxy"),
            ("Case {{Name}} {{name}}", ["name": "lower"], "Case  lower"),
            ("No recursion {{a}}", ["a": "{{b}}", "b": "B"], "No recursion {{b}}"),
            ("Malformed {{ a b }} {a} {{}} {{1x}}", ["a": "A", "1x": "y"], "Malformed {{ a b }} {a} {{}} {{1x}}"),
            ("Newline in braces {{\na}}", ["a": "A"], "Newline in braces {{\na}}"),
            ("Triple {{{a}}}", ["a": "A"], "Triple {A}"),
            ("Special $& $1 chars {{a}}", ["a": "$& and $1"], "Special $& $1 chars $& and $1"),
            ("{{a}}", ["a": "\\1 $& $1 \\\\"], "\\1 $& $1 \\\\"),
            ("Unicode {{a}}", ["a": "Se\u{00F1}or \u{1F697}"], "Unicode Se\u{00F1}or \u{1F697}"),
            ("{{a}} \u{2603} {{a}}", ["a": "\u{00E9}"], "\u{00E9} \u{2603} \u{00E9}"),
            ("{{_a1}} {{a_}}", ["_a1": "p", "a_": "q"], "p q"),
            ("{{a}}\nmiddle\n{{a}}", ["a": "x"], "x\nmiddle\nx"),
            ("no placeholders", ["a": "x"], "no placeholders"),
            ("", ["a": "x"], ""),
        ]
        for (template, values, expected) in cases {
            XCTAssertEqual(TemplateRenderer.render(template, values: values), expected, template)
        }
    }

    func testDottedAndDigitLeadingNamesStayLiteral() {
        // The server's name grammar is [A-Za-z_][A-Za-z0-9_]*.
        XCTAssertEqual(
            TemplateRenderer.render("{{customer.first_name}}", values: ["customer.first_name": "Ana"]),
            "{{customer.first_name}}"
        )
        XCTAssertEqual(TemplateRenderer.render("{{1x}}", values: ["1x": "y"]), "{{1x}}")
    }

    func testOnlySpacesAndTabsArePadding() {
        // NBSP, newline and other Unicode whitespace are not padding.
        XCTAssertEqual(TemplateRenderer.render("{{\u{00A0}a}}", values: ["a": "x"]), "{{\u{00A0}a}}")
        XCTAssertEqual(TemplateRenderer.render("{{a\u{2003}}}", values: ["a": "x"]), "{{a\u{2003}}}")
        XCTAssertEqual(TemplateRenderer.render("{{a\n}}", values: ["a": "x"]), "{{a\n}}")
        XCTAssertEqual(TemplateRenderer.render("{{ \t a \t }}", values: ["a": "x"]), "x")
    }

    func testLongNamesHaveNoCap() {
        let name = String(repeating: "a", count: 200)
        XCTAssertEqual(TemplateRenderer.render("[{{\(name)}}]", values: [name: "ok"]), "[ok]")
        XCTAssertEqual(TemplateRenderer.placeholders(in: "{{\(name)}}"), [name])
    }

    func testMalformedTokensLeftAlone() {
        XCTAssertEqual(TemplateRenderer.render("Price {{ ", values: [:]), "Price {{ ")
        XCTAssertEqual(TemplateRenderer.render("{{bad name}} ok", values: [:]), "{{bad name}} ok")
        XCTAssertEqual(TemplateRenderer.render("a }} b", values: [:]), "a }} b")
        XCTAssertEqual(TemplateRenderer.render("{{}}", values: [:]), "{{}}")
        XCTAssertEqual(TemplateRenderer.render("{{a}", values: ["a": "x"]), "{{a}")
        XCTAssertEqual(TemplateRenderer.render("{{a b}} {{a}}", values: ["a": "x"]), "{{a b}} x")
    }

    func testCombiningMarksNextToBraces() {
        // A combining mark after "}}" forms one grapheme with "}" in Swift,
        // but the server matches code points, so the placeholder still renders.
        XCTAssertEqual(TemplateRenderer.render("{{a}}\u{0301}", values: ["a": "x"]), "x\u{0301}")
        // A combining mark inside the name is not a name character.
        XCTAssertEqual(TemplateRenderer.render("{{a\u{0301}}}", values: ["a": "x"]), "{{a\u{0301}}}")
    }

    func testPlaceholdersList() {
        XCTAssertEqual(
            TemplateRenderer.placeholders(in: "{{a}} {{ b }} {{a}} {{bad name}} {{c.d}} {{{e}}} {{1f}}"),
            ["a", "b", "e"]
        )
    }

    func testIsValidName() {
        XCTAssertTrue(TemplateRenderer.isValidName("customer_first_name"))
        XCTAssertTrue(TemplateRenderer.isValidName("_a1"))
        XCTAssertFalse(TemplateRenderer.isValidName(""))
        XCTAssertFalse(TemplateRenderer.isValidName("1a"))
        XCTAssertFalse(TemplateRenderer.isValidName("shop.name"))
        XCTAssertFalse(TemplateRenderer.isValidName("caf\u{00E9}"))
    }
}

final class PhoneNumberTests: XCTestCase {

    func testNormalizeUS() {
        XCTAssertEqual(PhoneNumber.normalize("(205) 555-0123"), "+12055550123")
        XCTAssertEqual(PhoneNumber.normalize("205.555.0123"), "+12055550123")
        XCTAssertEqual(PhoneNumber.normalize("2055550123"), "+12055550123")
        XCTAssertEqual(PhoneNumber.normalize("1-205-555-0123"), "+12055550123")
        XCTAssertEqual(PhoneNumber.normalize("+1 205 555 0123"), "+12055550123")
        XCTAssertEqual(PhoneNumber.normalize(" +12055550123 "), "+12055550123")
        XCTAssertEqual(PhoneNumber.normalize("205-555-0123 x45"), "+12055550123")
        XCTAssertEqual(PhoneNumber.normalize("205-555-0123 ext. 45"), "+12055550123")
    }

    func testRejectsInvalidUS() {
        XCTAssertNil(PhoneNumber.normalize(""))
        XCTAssertNil(PhoneNumber.normalize("555-0123"))            // too short
        XCTAssertNil(PhoneNumber.normalize("105-555-0123"))        // area code starts with 1
        XCTAssertNil(PhoneNumber.normalize("205-155-0123"))        // exchange starts with 1
        XCTAssertNil(PhoneNumber.normalize("205555012345"))        // 12 digits, no +
        XCTAssertNil(PhoneNumber.normalize("call me"))
        XCTAssertNil(PhoneNumber.normalize("205-555-01a3"))
    }

    func testInternational() {
        XCTAssertEqual(PhoneNumber.normalize("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(PhoneNumber.normalize("0044 20 7946 0958"), "+442079460958")
        XCTAssertNil(PhoneNumber.normalize("+0 123 456 789"))
        XCTAssertNil(PhoneNumber.normalize("+1234"))
        XCTAssertEqual(PhoneNumber.normalize("+3531234567"), "+3531234567")   // 10 digits
        XCTAssertEqual(PhoneNumber.normalize("+2991234"), "+2991234")         // 7 digits (min)
        XCTAssertNil(PhoneNumber.normalize("+299123"))                        // 6 digits
        XCTAssertNil(PhoneNumber.normalize("+1234567890123456"))
    }

    func testFormat() {
        XCTAssertEqual(PhoneNumber.format("+12055550123"), "(205) 555-0123")
        XCTAssertEqual(PhoneNumber.format("2055550123"), "(205) 555-0123")
        XCTAssertEqual(PhoneNumber.format("+442079460958"), "+442079460958")
        XCTAssertEqual(PhoneNumber.format("not a phone"), "not a phone")
    }
}

final class VINTests: XCTestCase {

    func testKnownValidVINs() {
        XCTAssertEqual(VIN.validate("1M8GDM9AXKP042788"), .valid)     // check digit X
        XCTAssertEqual(VIN.validate("11111111111111111"), .valid)
        XCTAssertEqual(VIN.validate("1hgcm82633a004352"), .valid)     // lowercase accepted
        XCTAssertEqual(VIN.validate("1HG CM82-633A004352"), .valid)   // spaces/dashes stripped
    }

    func testCheckDigit() {
        XCTAssertEqual(VIN.checkDigit(for: "1M8GDM9AXKP042788"), "X")
        XCTAssertEqual(VIN.checkDigit(for: "1HGCM82633A004352"), "3")
        XCTAssertEqual(VIN.validate("1HGCM82643A004352"), .invalidCheckDigit)
        XCTAssertEqual(VIN.validate("1HGCM82643A004352", requireCheckDigit: false), .valid)
    }

    func testInvalid() {
        XCTAssertEqual(VIN.validate("1HGCM82633A00435"), .invalidLength)
        XCTAssertEqual(VIN.validate(""), .invalidLength)
        XCTAssertEqual(VIN.validate("1HGCM82633A00435I"), .invalidCharacters)
        XCTAssertEqual(VIN.validate("1HGCM8263OA004352"), .invalidCharacters)
        XCTAssertEqual(VIN.validate("QHGCM82633A004352"), .invalidCharacters)
    }

    func testModelYear() {
        XCTAssertEqual(VIN.modelYear("1HGCM82633A004352"), 2003)
        XCTAssertEqual(VIN.modelYear("1M8GDM9AXKP042788"), 1989)
        XCTAssertEqual(VIN.modelYear("5YJ3E1EA7LF000316"), 2020)
    }

    func testScanCandidatesFromBarcodePayloads() {
        XCTAssertEqual(VIN.candidates(in: "1HGCM82633A004352"), ["1HGCM82633A004352"])
        // Code 39 door-jamb labels prefix an "I".
        XCTAssertEqual(VIN.candidates(in: "I1HGCM82633A004352").first, "1HGCM82633A004352")
        XCTAssertEqual(VIN.candidates(in: "1hgcm82633a004352\n").first, "1HGCM82633A004352")
    }

    func testScanCandidatesFromText() {
        XCTAssertEqual(VIN.candidates(in: "VIN: 1HGCM82633A004352 MFD 03/03").first, "1HGCM82633A004352")
        XCTAssertEqual(VIN.candidates(in: "VIN 1HG CM826 33A 004352").first, "1HGCM82633A004352")
        XCTAssertEqual(VIN.candidates(in: "1HGCM-82633-A004352").first, "1HGCM82633A004352")
        // OCR read the zero as the letter O: corrected.
        XCTAssertEqual(VIN.candidates(in: "1HGCM82633AOO4352").first, "1HGCM82633A004352")
    }

    func testScanCandidatesPutVerifiedFirst() {
        // Wrong check digit is still offered (for confirmation) but after a
        // verified one, and duplicates are dropped.
        let found = VIN.candidates(in: "1HGCM82643A004352 1HGCM82633A004352 1HGCM82633A004352")
        XCTAssertEqual(found, ["1HGCM82633A004352", "1HGCM82643A004352"])
        XCTAssertTrue(VIN.candidates(in: "no vin here").isEmpty)
        XCTAssertTrue(VIN.candidates(in: "1HGCM82633A00435").isEmpty)
    }
}

final class ValidationTests: XCTestCase {

    func testEmails() {
        XCTAssertTrue(Validation.isValidEmail("ana@example.com"))
        XCTAssertTrue(Validation.isValidEmail(" first.last+tag@sub.example.co "))
        XCTAssertFalse(Validation.isValidEmail("ana@example"))
        XCTAssertFalse(Validation.isValidEmail("ana@@example.com"))
        XCTAssertFalse(Validation.isValidEmail("@example.com"))
        XCTAssertFalse(Validation.isValidEmail("ana@.com"))
        XCTAssertTrue(Validation.isValidEmail("ana@.b.com"))   // matches the DB regex
        XCTAssertFalse(Validation.isValidEmail("ana @example.com"))
        XCTAssertFalse(Validation.isValidEmail("ana@example."))
        XCTAssertFalse(Validation.isValidEmail(""))
        // Same leniency as public.is_valid_email: these pass the DB regex.
        XCTAssertTrue(Validation.isValidEmail("a@b.c"))
        XCTAssertTrue(Validation.isValidEmail("a@b..c"))
        XCTAssertTrue(Validation.isValidEmail("a@b.c."))
        XCTAssertFalse(Validation.isValidEmail("a@b."))
        XCTAssertFalse(Validation.isValidEmail(String(repeating: "a", count: 250) + "@b.co"))
        XCTAssertEqual(Validation.normalizedEmail(" Ana@Example.COM "), "ana@example.com")
    }

    func testSlugRules() {
        XCTAssertNil(Validation.slugProblem("gloss-co"))
        XCTAssertNil(Validation.slugProblem("abc"))
        XCTAssertNil(Validation.slugProblem("shop-123"))
        XCTAssertEqual(Validation.slugProblem("ab"), .tooShort)
        XCTAssertEqual(Validation.slugProblem(String(repeating: "a", count: Validation.slugMaxLength + 1)), .tooLong)
        XCTAssertNil(Validation.slugProblem(String(repeating: "a", count: Validation.slugMaxLength)))
        XCTAssertEqual(Validation.slugProblem("Gloss"), .invalidCharacters)
        XCTAssertEqual(Validation.slugProblem("gloss_co"), .invalidCharacters)
        XCTAssertEqual(Validation.slugProblem("glöss"), .invalidCharacters)
        XCTAssertEqual(Validation.slugProblem("-gloss"), .badHyphens)
        XCTAssertEqual(Validation.slugProblem("gloss-"), .badHyphens)
        XCTAssertNil(Validation.slugProblem("gl--oss"))            // allowed by the DB regex
        XCTAssertEqual(Validation.slugProblem("admin"), .reserved)
        XCTAssertEqual(Validation.slugProblem("support"), .reserved)
        XCTAssertNil(Validation.slugProblem("settings"))
        XCTAssertEqual(Validation.slugProblem("book"), .reserved)
        XCTAssertEqual(Validation.slugProblem("portal"), .reserved)
    }

    func testSuggestedSlug() {
        XCTAssertEqual(Validation.suggestedSlug(from: "Gloss & Go Detailing"), "gloss-and-go-detailing")
        XCTAssertEqual(Validation.suggestedSlug(from: "  José's  Café  "), "joses-cafe")
        XCTAssertEqual(Validation.suggestedSlug(from: "A+ Tint!!"), "a-tint")
        XCTAssertEqual(Validation.suggestedSlug(from: "!!!"), "")
        let long = Validation.suggestedSlug(from: String(repeating: "word ", count: 20))
        XCTAssertLessThanOrEqual(long.count, Validation.slugMaxLength)
        XCTAssertFalse(long.hasSuffix("-"))
        XCTAssertTrue(Validation.isValidSlug(long))
    }

    func testPassword() {
        XCTAssertFalse(Validation.isAcceptablePassword("short"))
        XCTAssertTrue(Validation.isAcceptablePassword("long enough"))
    }
}
