import { assert, assertEquals } from "@std/assert";
import { pdfSafe, wrapText } from "../_shared/pdf.ts";
import { PdfWriter } from "../_shared/pdf.ts";
import { extractPdfText, pdfText } from "../_shared/testing/pdf_text.ts";
import {
  formatDate,
  formatMoney,
  formatQuantity,
  formatRate,
  type InvoiceJson,
  type QuoteJson,
  renderInvoicePdf,
  renderQuotePdf,
} from "./render.ts";
import { INVOICE_JSON, QUOTE_JSON } from "./test_fixtures.ts";

Deno.test("render: formatting helpers", () => {
  assertEquals(formatMoney(123450, "usd"), "$1,234.50");
  assertEquals(formatMoney(-500, "usd"), "-$5.00");
  assertEquals(formatMoney(5000, "cad"), "CA$50.00");
  assertEquals(formatMoney(5000, "zzz1"), "50.00 ZZZ1");
  assertEquals(formatRate(825), "8.25%");
  assertEquals(formatRate(700), "7%");
  assertEquals(formatRate(0), "0%");
  assertEquals(formatQuantity(2), "2");
  assertEquals(formatQuantity(1.5), "1.5");
  assertEquals(formatQuantity("0.25"), "0.25");
  // A calendar date is printed as is; an instant in the shop's time zone.
  assertEquals(formatDate("2026-07-01", "Pacific/Kiritimati"), "Jul 1, 2026");
  assertEquals(formatDate("2026-06-02T03:00:00Z", "America/Chicago"), "Jun 1, 2026");
  assertEquals(formatDate(null, "UTC"), null);
});

Deno.test("pdf helpers: text outside WinAnsi is transliterated or replaced, never thrown", async () => {
  const w = await PdfWriter.create({ title: "t" });
  assertEquals(pdfSafe("Café – “quoted” €5 • ok", w.regular), "Café – “quoted” €5 • ok");
  assertEquals(pdfSafe("Łódź → Kraków", w.regular), "Lódz -> Kraków");
  assertEquals(pdfSafe("王 Motors", w.regular), "? Motors");
  assertEquals(pdfSafe("a\tb\nc", w.regular), "a b c");
  const lines = wrapText("word ".repeat(60) + "x".repeat(200), w.regular, 10, 200);
  assert(lines.length > 3);
  for (const line of lines) assert(w.regular.widthOfTextAtSize(line, 10) <= 200, line);
  assertEquals(wrapText("a\n\nb", w.regular, 10, 200), ["a", "", "b"]);
});

Deno.test("render: quote PDF shows header, lines, totals and text exactly as given", async () => {
  const bytes = await renderQuotePdf(QUOTE_JSON, { now: new Date("2026-06-03T00:00:00Z") });
  assertEquals(new TextDecoder().decode(bytes.slice(0, 5)), "%PDF-");
  const text = await pdfText(bytes);
  for (
    const expected of [
      "QUOTE",
      "#1042",
      "Shine Auto Spa",
      "12 Oak St",
      "Birmingham, AL 35203",
      "Date: Jun 1, 2026",
      "Valid until: Jul 1, 2026",
      "Status: Sent",
      "PREPARED FOR",
      "Dana Ruiz",
      "Ruiz Fleet LLC",
      "Vehicle: 2021 Honda Civic (Blue)",
      "Full detail",
      "Interior + exterior",
      "$400.00",
      "Ceramic spray",
      "Optional add-on",
      "$25.00",
      "Subtotal",
      "$450.00",
      "-$50.00",
      "Tax (8.25%)",
      "$33.00",
      "Total",
      "$433.00",
      "Notes",
      "Thanks for choosing us.",
      "Terms",
      "50% deposit to book.",
      "Shine Auto Spa - Quote #1042",
      "Page 1 of 1",
    ]
  ) {
    assert(text.includes(expected), `missing "${expected}" in:\n${text}`);
  }
  assertEquals(text.includes("DRAFT"), false);
});

Deno.test("render: quote options are listed with their own totals; drafts are marked", async () => {
  const data: QuoteJson = {
    ...QUOTE_JSON,
    quote: { ...QUOTE_JSON.quote, status: "approved", has_options: true, selected_option_id: "o2" },
    options: [
      {
        id: "o1",
        name: "Good",
        description: "Wash + wax",
        subtotal_cents: 10000,
        discount_cents: 0,
        tax_cents: 825,
        total_cents: 10825,
      },
      {
        id: "o2",
        name: "Best",
        description: null,
        subtotal_cents: 30000,
        discount_cents: 1000,
        tax_cents: 2393,
        total_cents: 31393,
      },
    ],
    line_items: [
      { name: "Hand wash", option_id: null, quantity: 1, unit_price_cents: 0, total_cents: 0 },
      { name: "Wax", option_id: "o1", quantity: 1, unit_price_cents: 10000, total_cents: 10000 },
      {
        name: "Ceramic coating",
        option_id: "o2",
        quantity: 1,
        unit_price_cents: 30000,
        total_cents: 30000,
      },
    ],
  };
  const text = await pdfText(await renderQuotePdf(data, { draft: true }));
  for (
    const expected of [
      "Included with every option",
      "Hand wash",
      "Option: Good",
      "Wash + wax",
      "$108.25",
      "Option: Best (chosen)",
      "Ceramic coating",
      "Option total",
      "$313.93",
      "Total (Best)",
      "DRAFT",
    ]
  ) {
    assert(text.includes(expected), `missing "${expected}"`);
  }
});

Deno.test("render: invoice PDF includes payments received and the balance", async () => {
  const text = await pdfText(await renderInvoicePdf(INVOICE_JSON));
  for (
    const expected of [
      "INVOICE",
      "#2001",
      "Issued: Jun 2, 2026",
      "Due: Jun 16, 2026",
      "Status: Partially paid",
      "BILL TO",
      "Vehicle: 2021 Honda Civic",
      "Job #1042",
      "Tax (7%)",
      "$428.00",
      "Amount paid",
      "$200.00",
      "Balance due",
      "$228.00",
      "Tips (not part of the total)",
      "$15.00",
      "Payments received",
      "Jun 1, 2026",
      "Visa ending 4242",
      "Plus tip $15.00",
      "Deposit",
      "Due in 14 days.",
    ]
  ) {
    assert(text.includes(expected), `missing "${expected}"`);
  }
});

Deno.test("render: a grouped invoice lists its jobs; a void invoice is marked VOID", async () => {
  const data: InvoiceJson = {
    ...INVOICE_JSON,
    invoice: { ...INVOICE_JSON.invoice, status: "void", voided_at: "2026-06-05T12:00:00Z" },
    job: null,
    vehicle: null,
    jobs: [
      { number: 1, date: "2026-06-01", vehicle_label: "2020 Ford F-150" },
      { number: 2, date: "2026-06-02", vehicle_label: "2019 Ram 1500" },
    ],
    payments: [],
  };
  const text = await pdfText(await renderInvoicePdf(data));
  assert(text.includes("Job #1 - Jun 1, 2026 - 2020 Ford F-150"));
  assert(text.includes("Job #2 - Jun 2, 2026 - 2019 Ram 1500"));
  assert(text.includes("VOID"));
  assert(text.includes("Voided: Jun 5, 2026"));
  assertEquals(text.includes("Payments received"), false);
});

Deno.test("render: long documents break across pages with numbered footers", async () => {
  const many = Array.from({ length: 60 }, (_, i) => ({
    name: `Service ${i + 1}`,
    description: "A long description ".repeat(4),
    quantity: 1,
    unit_price_cents: 1000,
    total_cents: 1000,
  }));
  const bytes = await renderInvoicePdf({ ...INVOICE_JSON, line_items: many });
  const text = await pdfText(bytes);
  const total = Number(/Page 1 of (\d+)/.exec(text)?.[1] ?? "0");
  assert(total >= 3, `expected several pages, got ${total}`);
  for (let page = 1; page <= total; page++) assert(text.includes(`Page ${page} of ${total}`));
  assert(text.includes("Service 60"));
  assertEquals((await extractPdfText(bytes)).length >= total, true);
});

Deno.test("render: a 5000-character line description is printed in full across pages", async () => {
  const words: string[] = [];
  let description = "";
  for (let i = 1; description.length + ` d${i}`.length <= 5000; i++) {
    words.push(`d${i}`);
    description = words.join(" ");
  }
  const bytes = await renderInvoicePdf({
    ...INVOICE_JSON,
    line_items: [{
      name: "Paint correction",
      description,
      quantity: 1,
      unit_price_cents: 90000,
      total_cents: 90000,
    }],
  });
  const text = await pdfText(bytes);
  const printed = text.split(/\s+/).filter((t) => /^d\d+$/.test(t));
  assertEquals(printed, words);
  assert(text.includes("Page 2 of"), "the description should continue on a second page");
  assert(text.includes("Balance due"));
});
