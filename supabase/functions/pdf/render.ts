/**
 * Quote and invoice PDFs from the curated JSON the public pages use
 * (money_public_quote_json / money_public_invoice_json). Every amount is
 * printed exactly as the database returned it: nothing is added up,
 * recomputed or rounded here (only formatted as currency).
 */
import {
  COLORS,
  type Column,
  CONTENT_WIDTH,
  embedImage,
  MARGIN,
  PAGE_WIDTH,
  PdfWriter,
} from "../_shared/pdf.ts";

// ---------------------------------------------------------------------------
// Input shapes (the RPC JSON; every field is treated as possibly missing)
// ---------------------------------------------------------------------------

export interface ShopJson {
  name?: string | null;
  email?: string | null;
  phone?: string | null;
  website?: string | null;
  address_line1?: string | null;
  address_line2?: string | null;
  city?: string | null;
  region?: string | null;
  postal_code?: string | null;
  country?: string | null;
  timezone?: string | null;
  currency?: string | null;
  logo_path?: string | null;
}

export interface CustomerJson {
  first_name?: string | null;
  last_name?: string | null;
  company?: string | null;
}

export interface VehicleJson {
  year?: number | null;
  make?: string | null;
  model?: string | null;
  trim?: string | null;
  color?: string | null;
}

export interface LineJson {
  id?: string | null;
  option_id?: string | null;
  name?: string | null;
  description?: string | null;
  vehicle_label?: string | null;
  job_number?: number | null;
  quantity?: number | string | null;
  unit_price_cents?: number | null;
  discount_cents?: number | null;
  total_cents?: number | null;
  optional?: boolean | null;
  selected?: boolean | null;
}

export interface OptionJson {
  id?: string | null;
  name?: string | null;
  description?: string | null;
  subtotal_cents?: number | null;
  discount_cents?: number | null;
  tax_cents?: number | null;
  total_cents?: number | null;
}

export interface QuoteJson {
  shop?: ShopJson | null;
  quote?: {
    number?: number | null;
    status?: string | null;
    valid_until?: string | null;
    notes?: string | null;
    terms?: string | null;
    subtotal_cents?: number | null;
    discount_cents?: number | null;
    tax_rate_bps?: number | null;
    tax_cents?: number | null;
    total_cents?: number | null;
    sent_at?: string | null;
    approved_at?: string | null;
    approved_by_name?: string | null;
    declined_at?: string | null;
    has_options?: boolean | null;
    selected_option_id?: string | null;
  } | null;
  customer?: CustomerJson | null;
  vehicle?: VehicleJson | null;
  options?: OptionJson[] | null;
  line_items?: LineJson[] | null;
}

export interface PaymentJson {
  kind?: string | null;
  method?: string | null;
  status?: string | null;
  amount_cents?: number | null;
  tip_cents?: number | null;
  refunded_cents?: number | null;
  card_brand?: string | null;
  card_last4?: string | null;
  paid_at?: string | null;
}

export interface InvoiceJson {
  shop?: ShopJson | null;
  invoice?: {
    number?: number | null;
    status?: string | null;
    issued_at?: string | null;
    due_at?: string | null;
    paid_at?: string | null;
    voided_at?: string | null;
    notes?: string | null;
    terms?: string | null;
    subtotal_cents?: number | null;
    discount_cents?: number | null;
    tax_rate_bps?: number | null;
    tax_cents?: number | null;
    total_cents?: number | null;
    amount_paid_cents?: number | null;
    balance_cents?: number | null;
    tip_cents?: number | null;
    processing_cents?: number | null;
  } | null;
  customer?: CustomerJson | null;
  job?: { number?: number | null; scheduled_start?: string | null } | null;
  vehicle?: VehicleJson | null;
  jobs?:
    | Array<{ number?: number | null; date?: string | null; vehicle_label?: string | null }>
    | null;
  line_items?: LineJson[] | null;
  payments?: PaymentJson[] | null;
}

export interface RenderOptions {
  /** Staff view of a draft: every page is marked DRAFT. */
  draft?: boolean;
  /** PNG/JPEG bytes of the shop logo (already size-checked). */
  logo?: Uint8Array | null;
  now?: Date;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

const currencyFormats = new Map<string, Intl.NumberFormat | null>();

/** Integer minor units -> "$1,234.50" in the shop currency. */
export function formatMoney(
  cents: number | null | undefined,
  currency: string | null | undefined,
): string {
  const value = typeof cents === "number" && Number.isFinite(cents) ? cents : 0;
  const code = (currency ?? "usd").toUpperCase();
  let format = currencyFormats.get(code);
  if (format === undefined) {
    try {
      format = new Intl.NumberFormat("en-US", { style: "currency", currency: code });
    } catch {
      format = null;
    }
    currencyFormats.set(code, format);
  }
  if (!format) return `${(value / 100).toFixed(2)} ${code}`;
  const digits = format.resolvedOptions().maximumFractionDigits ?? 2;
  return format.format(value / 10 ** digits);
}

/** A date for display: a calendar date as is, an instant in the shop's time zone. */
export function formatDate(
  value: string | null | undefined,
  timeZone: string | null | undefined,
): string | null {
  if (!value) return null;
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(value);
  const date = new Date(dateOnly ? `${value}T12:00:00Z` : value);
  if (Number.isNaN(date.getTime())) return null;
  const options: Intl.DateTimeFormatOptions = { year: "numeric", month: "short", day: "numeric" };
  try {
    return new Intl.DateTimeFormat("en-US", {
      ...options,
      timeZone: dateOnly ? "UTC" : timeZone ?? "UTC",
    })
      .format(date);
  } catch {
    return new Intl.DateTimeFormat("en-US", { ...options, timeZone: "UTC" }).format(date);
  }
}

/** 825 -> "8.25%", 700 -> "7%". */
export function formatRate(bps: number | null | undefined): string {
  const value = typeof bps === "number" ? bps : 0;
  return `${(value / 100).toFixed(2).replace(/\.?0+$/, "")}%`;
}

export function formatQuantity(quantity: number | string | null | undefined): string {
  const value = typeof quantity === "string" ? Number(quantity) : quantity ?? 1;
  if (!Number.isFinite(value)) return "1";
  return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0$/, "");
}

const QUOTE_STATUS: Readonly<Record<string, string>> = {
  draft: "Draft",
  sent: "Sent",
  viewed: "Viewed",
  approved: "Approved",
  declined: "Declined",
  expired: "Expired",
  converted: "Approved",
};

const INVOICE_STATUS: Readonly<Record<string, string>> = {
  draft: "Draft",
  open: "Open",
  partially_paid: "Partially paid",
  paid: "Paid",
  void: "Void",
};

const METHOD: Readonly<Record<string, string>> = {
  card: "Card",
  card_present: "Card (in person)",
  cash: "Cash",
  check: "Check",
  bank_transfer: "Bank transfer",
  ach_debit: "Bank debit (ACH)",
  bnpl: "Pay later",
  gift_card: "Gift card",
  other: "Other",
};

const KIND: Readonly<Record<string, string>> = {
  deposit: "Deposit",
  payment: "Payment",
  membership: "Membership",
};

function customerName(customer: CustomerJson | null | undefined): string[] {
  const name = [customer?.first_name, customer?.last_name].map((p) => p?.trim()).filter(Boolean)
    .join(" ");
  const company = customer?.company?.trim();
  return [name, company].filter((v): v is string => Boolean(v));
}

function vehicleLabel(vehicle: VehicleJson | null | undefined): string | null {
  if (!vehicle) return null;
  const base = [vehicle.year, vehicle.make, vehicle.model, vehicle.trim]
    .map((p) => (p === null || p === undefined ? "" : String(p).trim()))
    .filter(Boolean)
    .join(" ");
  if (!base) return null;
  return vehicle.color?.trim() ? `${base} (${vehicle.color.trim()})` : base;
}

function shopLines(shop: ShopJson | null | undefined): string[] {
  const cityLine = [
    shop?.city?.trim(),
    [shop?.region?.trim(), shop?.postal_code?.trim()].filter(Boolean).join(" "),
  ].filter(Boolean).join(", ");
  return [
    shop?.address_line1,
    shop?.address_line2,
    cityLine,
    shop?.phone,
    shop?.email,
    shop?.website,
  ].map((v) => v?.trim()).filter((v): v is string => Boolean(v));
}

function paymentMethodLabel(payment: PaymentJson): string {
  const method = METHOD[payment.method ?? ""] ?? "Payment";
  if (payment.card_last4) {
    const brand = payment.card_brand ? payment.card_brand.replace(/_/g, " ") : "Card";
    return `${brand.charAt(0).toUpperCase()}${brand.slice(1)} ending ${payment.card_last4}`;
  }
  return method;
}

// ---------------------------------------------------------------------------
// Shared blocks
// ---------------------------------------------------------------------------

const LINE_COLUMNS: Column[] = [
  { width: CONTENT_WIDTH - 50 - 85 - 85 },
  { width: 50, align: "right" },
  { width: 85, align: "right" },
  { width: 85, align: "right" },
];

async function header(
  w: PdfWriter,
  shop: ShopJson | null | undefined,
  title: string,
  number: string,
  facts: Array<[string, string | null]>,
  logo: Uint8Array | null | undefined,
): Promise<void> {
  const top = w.y;
  let leftBottom = top;
  if (logo) {
    const image = await embedImage(w.doc, logo);
    if (image) {
      const height = w.image(image, MARGIN, 160, 56);
      w.y -= height + 6;
    }
  }
  w.y -= 16;
  w.text(shop?.name?.trim() || "", { size: 15, bold: true });
  for (const line of shopLines(shop)) {
    w.y -= 12;
    w.text(line, { size: 9, color: COLORS.muted });
  }
  leftBottom = w.y;

  const right = PAGE_WIDTH - MARGIN;
  w.y = top - 20;
  w.text(title, { size: 20, bold: true, alignRight: right });
  w.y -= 16;
  w.text(number, { size: 11, alignRight: right });
  for (const [label, value] of facts) {
    if (!value) continue;
    w.y -= 13;
    w.text(`${label}: ${value}`, { size: 9, alignRight: right, color: COLORS.muted });
  }
  w.y = Math.min(leftBottom, w.y) - 18;
  w.rule();
}

function partyBlock(w: PdfWriter, heading: string, lines: string[]): void {
  if (lines.length === 0) return;
  w.y -= 18;
  w.text(heading.toUpperCase(), { size: 8, bold: true, color: COLORS.muted });
  for (const [index, line] of lines.entries()) {
    w.y -= 13;
    w.text(line, { size: 10, bold: index === 0 });
  }
}

function lineTable(
  w: PdfWriter,
  lines: readonly LineJson[],
  currency: string,
  showSelection: boolean,
): void {
  w.space(8);
  w.row(LINE_COLUMNS, [["Description"], ["Qty"], ["Unit price"], ["Amount"]], {
    bold: true,
    fill: true,
    size: 9,
  });
  for (const line of lines) {
    const details: string[] = [];
    if (line.description?.trim()) details.push(line.description.trim());
    if (line.vehicle_label?.trim()) details.push(`Vehicle: ${line.vehicle_label.trim()}`);
    if (typeof line.job_number === "number") details.push(`Job #${line.job_number}`);
    if (line.discount_cents && line.discount_cents > 0) {
      details.push(`Line discount: -${formatMoney(line.discount_cents, currency)}`);
    }
    if (line.optional) {
      details.push(
        showSelection
          ? (line.selected ? "Optional add-on (chosen)" : "Optional add-on (not chosen)")
          : "Optional add-on",
      );
    }
    w.row(LINE_COLUMNS, [
      [line.name?.trim() || "Item", ...details],
      [formatQuantity(line.quantity)],
      [formatMoney(line.unit_price_cents, currency)],
      [formatMoney(line.total_cents, currency)],
    ], { firstBold: true });
    w.rule();
  }
}

function textSection(w: PdfWriter, heading: string, body: string | null | undefined): void {
  const text = body?.trim();
  if (!text) return;
  w.ensure(40);
  w.y -= 22;
  w.text(heading, { size: 10, bold: true });
  w.space(2);
  w.paragraph(text, { size: 9, color: COLORS.muted });
}

// ---------------------------------------------------------------------------
// Quote
// ---------------------------------------------------------------------------

export async function renderQuotePdf(
  data: QuoteJson,
  options: RenderOptions = {},
): Promise<Uint8Array> {
  const shop = data.shop ?? {};
  const quote = data.quote ?? {};
  const currency = shop.currency ?? "usd";
  const tz = shop.timezone ?? "UTC";
  const number = typeof quote.number === "number" ? `#${quote.number}` : "";
  const status = quote.status ?? "";
  const w = await PdfWriter.create({
    title: `Quote ${number}`.trim(),
    subject: shop.name ?? undefined,
    watermark: options.draft || status === "draft" ? "DRAFT" : null,
    footer: [shop.name, `Quote ${number}`].filter(Boolean).join(" - "),
  }, options.now);

  await header(w, shop, "QUOTE", number, [
    ["Date", formatDate(quote.sent_at, tz)],
    ["Valid until", formatDate(quote.valid_until, tz)],
    ["Status", QUOTE_STATUS[status] ?? null],
  ], options.logo);

  const prepared = customerName(data.customer);
  const vehicle = vehicleLabel(data.vehicle);
  partyBlock(w, "Prepared for", [...prepared, ...(vehicle ? [`Vehicle: ${vehicle}`] : [])]);
  if (quote.approved_at) {
    w.y -= 14;
    const by = quote.approved_by_name?.trim() ? ` by ${quote.approved_by_name.trim()}` : "";
    w.text(`Approved${by} on ${formatDate(quote.approved_at, tz)}`, {
      size: 9,
      color: COLORS.muted,
    });
  } else if (quote.declined_at) {
    w.y -= 14;
    w.text(`Declined on ${formatDate(quote.declined_at, tz)}`, { size: 9, color: COLORS.muted });
  }

  const lines = data.line_items ?? [];
  const optionsList = data.options ?? [];
  const decided = status === "approved" || status === "converted";
  if (optionsList.length === 0) {
    lineTable(w, lines, currency, decided);
  } else {
    const shared = lines.filter((l) => !l.option_id);
    if (shared.length) {
      w.y -= 20;
      w.text("Included with every option", { size: 11, bold: true });
      lineTable(w, shared, currency, decided);
    }
    for (const option of optionsList) {
      const chosen = decided && option.id && option.id === quote.selected_option_id;
      w.ensure(90);
      w.y -= 24;
      w.text(`Option: ${option.name?.trim() || "Untitled"}${chosen ? " (chosen)" : ""}`, {
        size: 11,
        bold: true,
      });
      if (option.description?.trim()) {
        w.paragraph(option.description.trim(), { size: 9, color: COLORS.muted });
      }
      lineTable(
        w,
        lines.filter((l) => l.option_id && l.option_id === option.id),
        currency,
        decided,
      );
      const rows = [{
        label: "Option subtotal",
        value: formatMoney(option.subtotal_cents, currency),
      }];
      if (option.discount_cents) {
        rows.push({ label: "Discount", value: `-${formatMoney(option.discount_cents, currency)}` });
      }
      rows.push({ label: "Tax", value: formatMoney(option.tax_cents, currency) });
      w.totals([...rows, {
        label: "Option total",
        value: formatMoney(option.total_cents, currency),
        bold: true,
      }]);
    }
  }

  w.space(10);
  const totals: Array<{ label: string; value: string; bold?: boolean }> = [
    { label: "Subtotal", value: formatMoney(quote.subtotal_cents, currency) },
  ];
  if (quote.discount_cents) {
    totals.push({ label: "Discount", value: `-${formatMoney(quote.discount_cents, currency)}` });
  }
  totals.push({
    label: `Tax (${formatRate(quote.tax_rate_bps)})`,
    value: formatMoney(quote.tax_cents, currency),
  });
  const chosenOption = optionsList.find((o) => o.id && o.id === quote.selected_option_id);
  totals.push({
    label: chosenOption && optionsList.length > 1
      ? `Total (${chosenOption.name?.trim() || "option"})`
      : "Total",
    value: formatMoney(quote.total_cents, currency),
    bold: true,
  });
  w.totals(totals);

  textSection(w, "Notes", quote.notes);
  textSection(w, "Terms", quote.terms);
  return await w.finish();
}

// ---------------------------------------------------------------------------
// Invoice (with the payments received, so it doubles as the receipt)
// ---------------------------------------------------------------------------

const PAYMENT_COLUMNS: Column[] = [
  { width: 110 },
  { width: CONTENT_WIDTH - 110 - 110 - 95 },
  { width: 110 },
  { width: 95, align: "right" },
];

export async function renderInvoicePdf(
  data: InvoiceJson,
  options: RenderOptions = {},
): Promise<Uint8Array> {
  const shop = data.shop ?? {};
  const invoice = data.invoice ?? {};
  const currency = shop.currency ?? "usd";
  const tz = shop.timezone ?? "UTC";
  const number = typeof invoice.number === "number" ? `#${invoice.number}` : "";
  const status = invoice.status ?? "";
  const w = await PdfWriter.create({
    title: `Invoice ${number}`.trim(),
    subject: shop.name ?? undefined,
    watermark: options.draft || status === "draft" ? "DRAFT" : status === "void" ? "VOID" : null,
    footer: [shop.name, `Invoice ${number}`].filter(Boolean).join(" - "),
  }, options.now);

  await header(w, shop, "INVOICE", number, [
    ["Issued", formatDate(invoice.issued_at, tz)],
    ["Due", formatDate(invoice.due_at, tz)],
    ["Paid", formatDate(invoice.paid_at, tz)],
    ["Voided", formatDate(invoice.voided_at, tz)],
    ["Status", INVOICE_STATUS[status] ?? null],
  ], options.logo);

  const billTo = customerName(data.customer);
  const jobs = data.jobs ?? [];
  const details: string[] = [];
  if (jobs.length > 1) {
    for (const job of jobs) {
      details.push(
        [
          typeof job.number === "number" ? `Job #${job.number}` : "Job",
          formatDate(job.date, tz),
          job.vehicle_label?.trim(),
        ].filter(Boolean).join(" - "),
      );
    }
  } else {
    const vehicle = vehicleLabel(data.vehicle);
    if (vehicle) details.push(`Vehicle: ${vehicle}`);
    const job = data.job ?? (jobs[0] ? { number: jobs[0].number } : null);
    if (job && typeof job.number === "number") details.push(`Job #${job.number}`);
  }
  partyBlock(w, "Bill to", [...billTo, ...details]);

  lineTable(w, data.line_items ?? [], currency, false);

  w.space(10);
  const totals: Array<{ label: string; value: string; bold?: boolean }> = [
    { label: "Subtotal", value: formatMoney(invoice.subtotal_cents, currency) },
  ];
  if (invoice.discount_cents) {
    totals.push({ label: "Discount", value: `-${formatMoney(invoice.discount_cents, currency)}` });
  }
  totals.push(
    {
      label: `Tax (${formatRate(invoice.tax_rate_bps)})`,
      value: formatMoney(invoice.tax_cents, currency),
    },
    { label: "Total", value: formatMoney(invoice.total_cents, currency), bold: true },
    { label: "Amount paid", value: formatMoney(invoice.amount_paid_cents, currency) },
  );
  if (invoice.processing_cents && invoice.processing_cents > 0) {
    totals.push({ label: "Processing", value: formatMoney(invoice.processing_cents, currency) });
  }
  totals.push({
    label: "Balance due",
    value: formatMoney(invoice.balance_cents, currency),
    bold: true,
  });
  if (invoice.tip_cents && invoice.tip_cents > 0) {
    totals.push({
      label: "Tips (not part of the total)",
      value: formatMoney(invoice.tip_cents, currency),
    });
  }
  w.totals(totals);

  const payments = data.payments ?? [];
  if (payments.length) {
    w.ensure(60);
    w.y -= 26;
    w.text("Payments received", { size: 11, bold: true });
    w.space(6);
    w.row(PAYMENT_COLUMNS, [["Date"], ["Method"], ["Type"], ["Amount"]], {
      bold: true,
      fill: true,
      size: 9,
    });
    for (const payment of payments) {
      const notes: string[] = [];
      if (payment.tip_cents && payment.tip_cents > 0) {
        notes.push(`Plus tip ${formatMoney(payment.tip_cents, currency)}`);
      }
      if (payment.refunded_cents && payment.refunded_cents > 0) {
        notes.push(`Refunded ${formatMoney(payment.refunded_cents, currency)}`);
      }
      w.row(PAYMENT_COLUMNS, [
        [payment.status === "processing" ? "Processing" : formatDate(payment.paid_at, tz) ?? ""],
        [paymentMethodLabel(payment), ...notes],
        [KIND[payment.kind ?? ""] ?? ""],
        [formatMoney(payment.amount_cents, currency)],
      ]);
      w.rule();
    }
  }

  textSection(w, "Notes", invoice.notes);
  textSection(w, "Terms", invoice.terms);
  return await w.finish();
}
