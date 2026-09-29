/**
 * Test fixtures for the messaging function: a FakeSupabase whose RPC
 * handlers emulate the comms SQL (0033/0034) closely enough to exercise the
 * claim -> send -> mark pipeline, plus Twilio and Resend stubs on the same
 * FakeFetch. The SQL suite (supabase/tests) covers the real functions.
 */
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase, type Row } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { type Deps, makeHandler } from "./index.ts";

export const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
export const OWNER = "10000000-0000-4000-8000-000000000001";
export const MANAGER = "10000000-0000-4000-8000-000000000002";
export const TECH = "10000000-0000-4000-8000-000000000003";
export const OTHER_TECH = "10000000-0000-4000-8000-000000000004";
export const OUTSIDER = "10000000-0000-4000-8000-000000000005";
export const TECH_MEMBER = "20000000-0000-4000-8000-000000000003";
export const OTHER_TECH_MEMBER = "20000000-0000-4000-8000-000000000004";
export const CUSTOMER = "30000000-0000-4000-8000-000000000001";
export const OPTED_OUT_CUSTOMER = "30000000-0000-4000-8000-000000000002";
export const NO_EMAIL_CUSTOMER = "30000000-0000-4000-8000-000000000003";
export const OTHER_SHOP_CUSTOMER = "30000000-0000-4000-8000-000000000004";
export const JOB = "40000000-0000-4000-8000-000000000001";
export const UNASSIGNED_JOB = "40000000-0000-4000-8000-000000000002";
export const OPTED_OUT_JOB = "40000000-0000-4000-8000-000000000003";
export const QUOTE = "60000000-0000-4000-8000-000000000001";
export const DRAFT_QUOTE = "60000000-0000-4000-8000-000000000002";
export const OTHER_SHOP_QUOTE = "60000000-0000-4000-8000-000000000003";
export const INVOICE = "70000000-0000-4000-8000-000000000001";
export const DRAFT_INVOICE = "70000000-0000-4000-8000-000000000002";
export const VOID_INVOICE = "70000000-0000-4000-8000-000000000003";
export const QUOTE_TOKEN = "80000000-0000-4000-8000-000000000001";
export const INVOICE_TOKEN = "80000000-0000-4000-8000-000000000002";

export const SHOP_NUMBER = "+12055550100";
export const CUSTOMER_PHONE = "+12055550111";
export const TWILIO_MESSAGES_URL = "https://api.twilio.com/2010-04-01/Accounts/:sid/Messages.json";
export const TWILIO_NUMBERS_URL =
  "https://api.twilio.com/2010-04-01/Accounts/:sid/IncomingPhoneNumbers.json";
export const PUBLIC_BASE = "https://fake-project.supabase.co/functions/v1";
/** The inbound webhook the platform configures on a shop's number. */
export function inboundWebhookUrl(shopId: string): string {
  return `${PUBLIC_BASE}/messaging?action=twilio_inbound&shop_id=${shopId}#rc=3&rp=all`;
}
export const RESEND_URL = "https://api.resend.com/emails";
export const CRON_SECRET = "fake-cron-secret-0123456789abcdef";
export const NOW = new Date("2026-09-27T15:00:00.000Z");

const TECH_KEYS = ["on_the_way", "job_started", "job_completed"];
/** comms_is_appointment_key / comms_is_marketing_key (0033). */
const APPOINTMENT_KEYS = [
  "booking_request_received",
  "booking_confirmed",
  "appointment_reminder",
  "on_the_way",
  "job_started",
];
const MARKETING_KEYS = ["follow_up", "service_followup"];
export const APP_BASE = "https://app.example.com";

function member(id: string, userId: string, role: string, shopId = SHOP): Row {
  return { id, shop_id: shopId, user_id: userId, role, display_name: role, active: true };
}

export function queuedMessage(overrides: Row = {}): Row {
  return {
    id: crypto.randomUUID(),
    shop_id: SHOP,
    customer_id: CUSTOMER,
    job_id: null,
    campaign_id: null,
    template_key: null,
    unsubscribe_token: null,
    direction: "outbound",
    channel: "sms",
    to_address: CUSTOMER_PHONE,
    from_address: null,
    subject: null,
    body: "Hello from Shine",
    status: "queued",
    send_after: "2026-09-27T14:00:00.000Z",
    provider_message_id: null,
    error: null,
    attempts: 0,
    claimed_at: null,
    sent_at: null,
    delivered_at: null,
    created_at: "2026-09-27T14:00:00.000Z",
    ...overrides,
  };
}

function roleOf(db: FakeSupabase, userId: string | null, shopId: string): string | null {
  const row = db.table("shop_members").find((m) =>
    m.user_id === userId && m.shop_id === shopId && m.active === true
  );
  return (row?.role as string | undefined) ?? null;
}

/** created_at for rows the fake RPCs insert: NOW + a counter, so insertion order is visible. */
let insertSeq = 0;

function insertMessage(db: FakeSupabase, row: Row): Row {
  insertSeq += 1;
  const full = queuedMessage({
    created_at: new Date(NOW.getTime() + insertSeq).toISOString(),
    ...row,
  });
  db.seed("messages", [...db.table("messages"), full]);
  return full;
}

function updateMessage(db: FakeSupabase, id: string, patch: Row): Row {
  const rows = db.table("messages");
  const row = rows.find((m) => m.id === id);
  if (!row) throw new FakeRpcError("P0002", "message not found");
  Object.assign(row, patch);
  db.seed("messages", rows);
  return row;
}

/** comms_customer_vars (0033): customer/shop variables, no job. */
function customerVars(db: FakeSupabase, shopId: string, customerId: string): Row {
  const shop = db.table("shops").find((s) => s.id === shopId);
  const customer = db.table("customers").find((c) => c.id === customerId && c.shop_id === shopId);
  return {
    customer_first_name: customer ? (customer.first_name ?? "there") : null,
    customer_name: customer?.first_name ?? null,
    shop_name: shop?.name ?? null,
    shop_phone: shop?.phone ?? null,
    review_link: shop?.review_url ?? null,
    booking_page_link: `${APP_BASE}/book/${shop?.slug}`,
  };
}

/** comms_job_vars (0033): customer vars + the job's (null for an unknown job). */
function jobVars(db: FakeSupabase, jobId: string): Row | null {
  const job = db.table("jobs").find((j) => j.id === jobId);
  if (!job) return null;
  return {
    ...customerVars(db, String(job.shop_id), String(job.customer_id)),
    vehicle: job.vehicle ?? null,
    booking_link: `${APP_BASE}/booking/${job.id}`,
    quote_link: job.quote_token ? `${APP_BASE}/q/${job.quote_token}` : null,
    invoice_link: job.invoice_token ? `${APP_BASE}/i/${job.invoice_token}` : null,
  };
}

/**
 * messages.request_nonce (0033): an earlier message queued by the same
 * sender with the same nonce in the shop is returned instead of a new one.
 */
function byNonce(
  db: FakeSupabase,
  shopId: string,
  sentBy: string | null,
  nonce: unknown,
): Row | undefined {
  if (nonce === undefined || nonce === null) return undefined;
  if (typeof nonce !== "string" || !/^[A-Za-z0-9_-]{8,64}$/.test(nonce)) {
    throw new FakeRpcError("22023", "request_nonce must be 8-64 letters, digits, - or _");
  }
  return db.table("messages").find((m) =>
    m.shop_id === shopId && (m.sent_by ?? null) === sentBy && m.request_nonce === nonce
  );
}

/** comms_document_vars (0090): the document's variables, link null until sent / issued. */
function documentVars(db: FakeSupabase, quoteId: unknown, invoiceId: unknown): Row {
  if (
    (quoteId === null || quoteId === undefined) === (invoiceId === null || invoiceId === undefined)
  ) {
    throw new FakeRpcError("22023", "give exactly one of a quote or an invoice");
  }
  const isQuote = quoteId !== null && quoteId !== undefined;
  const doc = db.table(isQuote ? "quotes" : "invoices").find((d) =>
    d.id === (isQuote ? quoteId : invoiceId)
  );
  if (!doc) throw new FakeRpcError("P0002", `${isQuote ? "quote" : "invoice"} not found`);
  const jobId = isQuote ? doc.converted_job_id : doc.job_id;
  const job = jobId
    ? db.table("jobs").find((j) => j.id === jobId && j.customer_id === doc.customer_id)
    : undefined;
  const base = job
    ? jobVars(db, String(job.id)) ?? {}
    : customerVars(db, String(doc.shop_id), String(doc.customer_id));
  const amount = `$${(Number(doc.total_cents) / 100).toFixed(2)}`;
  if (isQuote) {
    return {
      ...base,
      quote_link: doc.status === "draft" ? null : `${APP_BASE}/q/${doc.public_token}`,
      amount,
      balance: null,
    };
  }
  return {
    ...base,
    invoice_link: doc.status === "draft" || doc.status === "void"
      ? null
      : `${APP_BASE}/i/${doc.public_token}`,
    amount,
    balance: `$${(Math.max(Number(doc.balance_cents), 0) / 100).toFixed(2)}`,
  };
}

/** Emulates enqueue_customer_template's consent/address checks; returns the new id or null. */
/** Mirrors comms_shop_postal_address (0119): null without a street line and city. */
function postalAddress(shop: Row | undefined): string | null {
  const text = (value: unknown) => typeof value === "string" ? value.trim() : "";
  if (!shop || text(shop.address_line1) === "" || text(shop.city) === "") return null;
  const regionPostal = [text(shop.region), text(shop.postal_code)].filter((p) => p).join(" ");
  return [
    text(shop.address_line1),
    text(shop.address_line2),
    text(shop.city),
    regionPostal,
    shop.country && shop.country !== "US" ? String(shop.country) : "",
  ].filter((p) => p !== "").join(", ");
}

function enqueueTemplate(
  db: FakeSupabase,
  shopId: string,
  customerId: string,
  key: string,
  channel: string,
  jobId: string | null,
  sentBy: string | null,
  options: { nonce?: unknown; vars?: Row } = {},
): string | null {
  const replay = byNonce(db, shopId, sentBy, options.nonce);
  if (replay) return replay.id as string;
  const customer = db.table("customers").find((c) => c.id === customerId && c.shop_id === shopId);
  if (!customer) throw new FakeRpcError("P0002", "customer not found");
  const job = jobId ? db.table("jobs").find((j) => j.id === jobId) : undefined;
  if (
    job && (job.status === "cancelled" || job.status === "no_show") &&
    APPOINTMENT_KEYS.includes(key)
  ) {
    return null;
  }
  const template = db.table("message_templates").find((t) =>
    t.shop_id === shopId && t.key === key && t.channel === channel
  );
  if (!template || template.enabled !== true) return null;
  const shop = db.table("shops").find((s) => s.id === shopId);
  if (channel === "sms") {
    if (!customer.phone || customer.sms_opted_out_at || !shop?.sms_from_number) return null;
  } else if (!customer.email || customer.email_opted_out_at) return null;
  if (
    MARKETING_KEYS.includes(key) &&
    (channel === "sms" ? customer.sms_opt_in : customer.email_opt_in) !== true
  ) {
    return null;
  }
  // 0033: the key's own link must render (a draft quote / invoice has none)
  const required = key === "quote_sent"
    ? "quote_link"
    : key === "invoice_sent"
    ? "invoice_link"
    : null;
  const vars = options.vars ??
    (jobId ? jobVars(db, jobId) : customerVars(db, shopId, customerId)) ?? {};
  if (required && `${template.body}`.includes(`{{${required}}}`) && !vars[required]) {
    return null;
  }
  // 0033: marketing email gets its own random unsubscribe token and link
  const unsubscribeToken = channel === "email" && MARKETING_KEYS.includes(key)
    ? crypto.randomUUID()
    : null;
  let body = `${template.body}`.replaceAll(
    "{{unsubscribe_link}}",
    unsubscribeToken ? `${APP_BASE}/u/${unsubscribeToken}` : "",
  );
  for (const [name, value] of Object.entries(options.vars ?? {})) {
    body = body.replaceAll(`{{${name}}}`, value === null ? "" : String(value));
  }
  // 0119 messages_02_marketing_postal_address: without the shop's street
  // line and city a non-campaign marketing email is not inserted (null).
  if (unsubscribeToken && postalAddress(shop) === null) return null;
  const row = insertMessage(db, {
    shop_id: shopId,
    customer_id: customerId,
    job_id: jobId,
    channel,
    template_key: key,
    to_address: channel === "sms" ? customer.phone : customer.email,
    subject: channel === "email" ? `${template.subject}` : null,
    body,
    sent_by: sentBy,
    send_after: NOW.toISOString(),
    unsubscribe_token: unsubscribeToken,
    request_nonce: options.nonce ?? null,
  });
  return row.id as string;
}

export interface Fixture {
  db: FakeSupabase;
  handler: (req: Request) => Promise<Response>;
  logs: ReturnType<typeof memoryLogger>;
}

export function setup(
  options: {
    env?: Record<string, string | undefined>;
    messages?: Row[];
    concurrency?: number;
    /** Numbers on the fake Twilio account (default: SHOP_NUMBER bound to SHOP). */
    twilioNumbers?: Row[];
    /** Extra handler dependencies (timeouts, time budget). */
    deps?: Pick<Deps, "providerTimeoutMs" | "queueTimeBudgetMs">;
  } = {},
): Fixture {
  const db = new FakeSupabase({
    env: options.env,
    users: {
      "tok-owner": { id: OWNER, email: "owner@example.com" },
      "tok-manager": { id: MANAGER, email: "manager@example.com" },
      "tok-tech": { id: TECH, email: "tech@example.com" },
      "tok-other-tech": { id: OTHER_TECH, email: "tech2@example.com" },
      "tok-outsider": { id: OUTSIDER, email: "outsider@example.com" },
    },
    tables: {
      shop_members: [
        member("20000000-0000-4000-8000-000000000001", OWNER, "owner"),
        member("20000000-0000-4000-8000-000000000002", MANAGER, "manager"),
        member(TECH_MEMBER, TECH, "technician"),
        member(OTHER_TECH_MEMBER, OTHER_TECH, "technician"),
        member("20000000-0000-4000-8000-000000000005", OUTSIDER, "owner", OTHER_SHOP),
      ],
      shops: [
        {
          id: SHOP,
          name: "Shine Auto Spa",
          email: "hello@shine.example",
          phone: "+12055550100",
          sms_from_number: SHOP_NUMBER,
          slug: "shine",
          review_url: "https://g.page/r/shine/review",
          address_line1: "100 Main St",
          city: "Birmingham",
          region: "AL",
          postal_code: "35203",
          country: "US",
        },
        { id: OTHER_SHOP, name: "Other", email: null, phone: null, sms_from_number: null },
      ],
      // the platform's binding of each Twilio number to its shop (0033)
      shop_sms_numbers: [{ phone_number: SHOP_NUMBER, shop_id: SHOP }],
      customers: [
        {
          id: CUSTOMER,
          shop_id: SHOP,
          phone: CUSTOMER_PHONE,
          email: "dana@example.com",
          sms_opt_in: true,
          email_opt_in: true,
          sms_opted_out_at: null,
          email_opted_out_at: null,
        },
        {
          id: OPTED_OUT_CUSTOMER,
          shop_id: SHOP,
          phone: "+12055550122",
          email: "gone@example.com",
          sms_opted_out_at: "2026-09-01T00:00:00Z",
          email_opted_out_at: null,
        },
        {
          id: NO_EMAIL_CUSTOMER,
          shop_id: SHOP,
          phone: "+12055550133",
          email: null,
          sms_opted_out_at: null,
          email_opted_out_at: null,
        },
        {
          id: OTHER_SHOP_CUSTOMER,
          shop_id: OTHER_SHOP,
          phone: "+12055550144",
          email: null,
          sms_opted_out_at: null,
          email_opted_out_at: null,
        },
      ],
      jobs: [
        {
          id: JOB,
          shop_id: SHOP,
          customer_id: CUSTOMER,
          status: "scheduled",
          vehicle: "2021 Tesla Model 3",
        },
        { id: UNASSIGNED_JOB, shop_id: SHOP, customer_id: CUSTOMER, status: "scheduled" },
        { id: OPTED_OUT_JOB, shop_id: SHOP, customer_id: OPTED_OUT_CUSTOMER, status: "scheduled" },
      ],
      quotes: [
        {
          id: QUOTE,
          shop_id: SHOP,
          customer_id: CUSTOMER,
          converted_job_id: null,
          status: "sent",
          total_cents: 45000,
          public_token: QUOTE_TOKEN,
        },
        {
          id: DRAFT_QUOTE,
          shop_id: SHOP,
          customer_id: CUSTOMER,
          converted_job_id: null,
          status: "draft",
          total_cents: 12000,
          public_token: "80000000-0000-4000-8000-000000000003",
        },
        {
          id: OTHER_SHOP_QUOTE,
          shop_id: OTHER_SHOP,
          customer_id: OTHER_SHOP_CUSTOMER,
          converted_job_id: null,
          status: "sent",
          total_cents: 1000,
          public_token: "80000000-0000-4000-8000-000000000004",
        },
      ],
      invoices: [
        {
          id: INVOICE,
          shop_id: SHOP,
          customer_id: CUSTOMER,
          job_id: null,
          status: "open",
          total_cents: 30000,
          balance_cents: 20000,
          public_token: INVOICE_TOKEN,
        },
        {
          id: DRAFT_INVOICE,
          shop_id: SHOP,
          customer_id: CUSTOMER,
          job_id: JOB,
          status: "draft",
          total_cents: 5000,
          balance_cents: 5000,
          public_token: "80000000-0000-4000-8000-000000000005",
        },
        {
          id: VOID_INVOICE,
          shop_id: SHOP,
          customer_id: CUSTOMER,
          job_id: null,
          status: "void",
          total_cents: 5000,
          balance_cents: 0,
          public_token: "80000000-0000-4000-8000-000000000006",
        },
      ],
      job_assignments: [
        {
          id: "50000000-0000-4000-8000-000000000001",
          shop_id: SHOP,
          job_id: JOB,
          member_id: TECH_MEMBER,
        },
        {
          id: "50000000-0000-4000-8000-000000000002",
          shop_id: SHOP,
          job_id: OPTED_OUT_JOB,
          member_id: TECH_MEMBER,
        },
      ],
      message_templates: [
        {
          shop_id: SHOP,
          key: "on_the_way",
          channel: "sms",
          subject: null,
          body: "On our way!",
          enabled: true,
        },
        {
          shop_id: SHOP,
          key: "job_completed",
          channel: "email",
          subject: "All done",
          body: "Your car is ready.",
          enabled: true,
        },
        {
          shop_id: SHOP,
          key: "review_request",
          channel: "sms",
          subject: null,
          body: "Review us",
          enabled: false,
        },
        {
          shop_id: SHOP,
          key: "follow_up",
          channel: "sms",
          subject: null,
          body: "Checking in",
          enabled: true,
        },
        {
          shop_id: SHOP,
          key: "quote_sent",
          channel: "sms",
          subject: null,
          body: "Your quote for {{amount}}: {{quote_link}}",
          enabled: true,
        },
        {
          shop_id: SHOP,
          key: "invoice_sent",
          channel: "sms",
          subject: null,
          body: "Your invoice: {{amount}}, {{balance}} due. Pay: {{invoice_link}}",
          enabled: true,
        },
        {
          shop_id: SHOP,
          key: "invoice_sent",
          channel: "email",
          subject: "Your invoice",
          body: "Pay {{balance}} here: {{invoice_link}}",
          enabled: false,
        },
      ],
      messages: options.messages ?? [],
    },
  });

  db.onRpc("claim_queued_messages", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    const limit = Number(args.p_limit ?? 50);
    const due = ctx.db.table("messages")
      .filter((m) =>
        m.status === "queued" && m.direction === "outbound" &&
        Date.parse(String(m.send_after)) <= NOW.getTime()
      )
      .sort((a, b) => String(a.send_after).localeCompare(String(b.send_after)))
      .slice(0, limit);
    const out: Row[] = [];
    for (const m of due) {
      const shop = ctx.db.table("shops").find((s) => s.id === m.shop_id);
      const customer = ctx.db.table("customers").find((c) => c.id === m.customer_id);
      const optedOut = m.channel === "sms"
        ? Boolean(customer?.sms_opted_out_at)
        : Boolean(customer?.email_opted_out_at);
      if (optedOut) {
        updateMessage(ctx.db, String(m.id), { status: "cancelled", error: "opted out" });
        continue;
      }
      if (m.channel === "sms" && !shop?.sms_from_number) {
        updateMessage(ctx.db, String(m.id), { status: "failed", error: "no sms number" });
        continue;
      }
      const updated = updateMessage(ctx.db, String(m.id), {
        status: "sending",
        attempts: Number(m.attempts) + 1,
        claimed_at: NOW.toISOString(),
        from_address: m.channel === "sms" ? shop?.sms_from_number : m.from_address,
      });
      out.push({
        id: updated.id,
        shop_id: updated.shop_id,
        channel: updated.channel,
        to_address: updated.to_address,
        from_address: updated.from_address,
        subject: updated.subject,
        body: updated.body,
        attempts: updated.attempts,
        shop_name: shop?.name,
        reply_to: shop?.email ?? null,
        customer_id: updated.customer_id,
        job_id: updated.job_id,
        campaign_id: updated.campaign_id,
        template_key: updated.template_key,
        unsubscribe_token: updated.unsubscribe_token ?? null,
        // 0089: the Messaging Service of the shop's sending number
        messaging_service_sid: m.channel === "sms"
          ? ctx.db.table("shop_sms_numbers").find((n) =>
            n.shop_id === m.shop_id && n.phone_number === shop?.sms_from_number
          )?.messaging_service_sid ?? null
          : null,
      });
    }
    return out;
  });

  db.onRpc("mark_message_result", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    const id = String(args.p_id);
    const msg = ctx.db.table("messages").find((m) => m.id === id);
    if (!msg) throw new FakeRpcError("P0002", "message not found");
    if (msg.status !== "sending") {
      throw new FakeRpcError("55000", `message is ${msg.status}`);
    }
    if (args.p_status === "queued") {
      if (Number(msg.attempts) >= 5) {
        return updateMessage(ctx.db, id, { status: "failed", error: args.p_error ?? "failed" });
      }
      return updateMessage(ctx.db, id, {
        status: "queued",
        error: args.p_error ?? null,
        claimed_at: null,
        send_after: new Date(NOW.getTime() + 2 ** Number(msg.attempts) * 60_000).toISOString(),
      });
    }
    return updateMessage(ctx.db, id, {
      status: args.p_status,
      provider_message_id: args.p_provider_id ?? msg.provider_message_id,
      from_address: args.p_from_address ?? msg.from_address,
      error: args.p_status === "failed" ? (args.p_error ?? "sending failed") : null,
      sent_at: args.p_status === "sent" ? NOW.toISOString() : msg.sent_at,
    });
  });

  db.onRpc("update_message_status_by_provider_id", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    const msg = ctx.db.table("messages").find((m) => m.provider_message_id === args.p_provider_id);
    if (!msg) return null;
    updateMessage(ctx.db, String(msg.id), {
      status: args.p_status,
      error: args.p_status === "failed" ? args.p_error : null,
    });
    return msg.id;
  });

  db.onRpc("record_inbound_sms", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    const e164 = /^\+[1-9]\d{6,14}$/;
    if (!e164.test(String(args.p_to)) || !e164.test(String(args.p_from))) {
      throw new FakeRpcError("22023", "to and from must be E.164 phone numbers");
    }
    // 0033: routed by the platform binding (shop_sms_numbers), not sms_from_number
    const binding = ctx.db.table("shop_sms_numbers").find((n) => n.phone_number === args.p_to);
    const shop = binding ? ctx.db.table("shops").find((s) => s.id === binding.shop_id) : undefined;
    if (!shop) return [];
    const existing = args.p_provider_id
      ? ctx.db.table("messages").find((m) => m.provider_message_id === args.p_provider_id)
      : undefined;
    if (existing) {
      // Twilio retry: idempotent per MessageSid, no keyword action.
      return [{
        message_id: existing.id,
        shop_id: existing.shop_id,
        customer_id: existing.customer_id,
        opt_action: null,
      }];
    }
    const customer = ctx.db.table("customers").find((c) =>
      c.shop_id === shop.id && c.phone === args.p_from
    );
    const word = String(args.p_body).trim().replace(/[\s\p{P}\p{S}]+$/u, "").toUpperCase();
    let action: string | null = null;
    if (word === "START" || word === "UNSTOP" || word === "YES") {
      // 0033: START / UNSTOP / YES (Twilio's opt-in keywords) opt back in.
      action = "opt_in";
      const customers = ctx.db.table("customers");
      for (const c of customers) {
        if (c.shop_id === shop.id && c.phone === args.p_from) c.sms_opted_out_at = null;
      }
      ctx.db.seed("customers", customers);
    }
    if (word === "STOP") {
      action = "opt_out";
      const customers = ctx.db.table("customers");
      for (const c of customers) {
        if (c.shop_id === shop.id && c.phone === args.p_from) {
          c.sms_opted_out_at = NOW.toISOString();
        }
      }
      ctx.db.seed("customers", customers);
    }
    const row = insertMessage(ctx.db, {
      shop_id: shop.id,
      customer_id: customer?.id ?? null,
      direction: "inbound",
      status: "received",
      to_address: args.p_to,
      from_address: args.p_from,
      body: args.p_body,
      provider_message_id: args.p_provider_id,
    });
    return [{
      message_id: row.id,
      shop_id: shop.id,
      customer_id: customer?.id ?? null,
      opt_action: action,
    }];
  });

  db.onRpc("queue_message", (args, ctx) => {
    if (ctx.role !== "authenticated") throw new FakeRpcError("42501", "must be called as a user");
    const shopId = String(args.p_shop_id);
    const role = roleOf(ctx.db, ctx.userId, shopId);
    if (!role || role === "technician") {
      throw new FakeRpcError("42501", "only owners, admins and managers can message customers");
    }
    const replay = byNonce(ctx.db, shopId, ctx.userId, args.p_request_nonce);
    if (replay) return replay;
    const customer = ctx.db.table("customers").find((c) =>
      c.id === args.p_customer_id && c.shop_id === shopId
    );
    if (!customer) throw new FakeRpcError("P0002", "customer not found");
    const channel = String(args.p_channel);
    if (channel === "sms") {
      if (!customer.phone) throw new FakeRpcError("22023", "this customer has no mobile number");
      if (customer.sms_opted_out_at) throw new FakeRpcError("55000", "opted out");
    } else {
      if (!customer.email) throw new FakeRpcError("22023", "this customer has no email address");
      if (customer.email_opted_out_at) throw new FakeRpcError("55000", "unsubscribed");
    }
    return insertMessage(ctx.db, {
      shop_id: shopId,
      customer_id: customer.id,
      job_id: args.p_job_id ?? null,
      channel,
      to_address: channel === "sms" ? customer.phone : customer.email,
      subject: channel === "email" ? (args.p_subject ?? "Message from Shine Auto Spa") : null,
      body: args.p_body,
      sent_by: ctx.userId,
      send_after: NOW.toISOString(),
      request_nonce: args.p_request_nonce ?? null,
    });
  });

  db.onRpc("enqueue_template_message", (args, ctx) => {
    if (ctx.role !== "authenticated") throw new FakeRpcError("42501", "must be called as a user");
    const job = ctx.db.table("jobs").find((j) => j.id === args.p_job_id);
    if (!job) throw new FakeRpcError("P0002", "job not found");
    const role = roleOf(ctx.db, ctx.userId, String(job.shop_id));
    if (!role) throw new FakeRpcError("P0002", "job not found");
    if (role === "technician") {
      const memberRow = ctx.db.table("shop_members").find((m) => m.user_id === ctx.userId);
      const assigned = ctx.db.table("job_assignments").some((a) =>
        a.job_id === job.id && a.member_id === memberRow?.id
      );
      if (!assigned || !TECH_KEYS.includes(String(args.p_key))) {
        throw new FakeRpcError("42501", "technicians are restricted");
      }
    }
    if (
      (job.status === "cancelled" || job.status === "no_show") &&
      APPOINTMENT_KEYS.includes(String(args.p_key))
    ) {
      throw new FakeRpcError("55000", "this appointment is cancelled");
    }
    return enqueueTemplate(
      ctx.db,
      String(job.shop_id),
      String(job.customer_id),
      String(args.p_key),
      String(args.p_channel ?? "sms"),
      String(job.id),
      ctx.userId,
      { nonce: args.p_request_nonce },
    );
  });

  db.onRpc("enqueue_customer_template", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    return enqueueTemplate(
      ctx.db,
      String(args.p_shop_id),
      String(args.p_customer_id),
      String(args.p_key),
      String(args.p_channel ?? "sms"),
      (args.p_job_id as string | undefined) ?? null,
      (args.p_sent_by as string | undefined) ?? null,
      { nonce: args.p_request_nonce },
    );
  });

  db.onRpc("comms_shop_postal_address", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    return postalAddress(ctx.db.table("shops").find((s) => s.id === args.p_shop_id));
  });

  db.onRpc("comms_document_vars", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    return documentVars(ctx.db, args.p_quote_id, args.p_invoice_id);
  });

  // enqueue_document_message (0090), as the caller: manager+ of the
  // document's shop (another shop's or an unknown document: P0002).
  db.onRpc("enqueue_document_message", (args, ctx) => {
    if (ctx.role !== "authenticated") throw new FakeRpcError("42501", "must be called as a user");
    const isQuote = args.p_quote_id !== null && args.p_quote_id !== undefined;
    const doc = ctx.db.table(isQuote ? "quotes" : "invoices").find((d) =>
      d.id === (isQuote ? args.p_quote_id : args.p_invoice_id)
    );
    const role = doc ? roleOf(ctx.db, ctx.userId, String(doc.shop_id)) : null;
    if (!doc || !role) throw new FakeRpcError("P0002", "document not found");
    if (role === "technician") {
      throw new FakeRpcError("42501", "only owners, admins and managers can send quotes");
    }
    const jobId = isQuote ? doc.converted_job_id : doc.job_id;
    const job = jobId
      ? ctx.db.table("jobs").find((j) => j.id === jobId && j.customer_id === doc.customer_id)
      : undefined;
    return enqueueTemplate(
      ctx.db,
      String(doc.shop_id),
      String(doc.customer_id),
      isQuote ? "quote_sent" : "invoice_sent",
      String(args.p_channel ?? "sms"),
      (job?.id as string | undefined) ?? null,
      ctx.userId,
      {
        nonce: args.p_request_nonce,
        vars: documentVars(ctx.db, args.p_quote_id, args.p_invoice_id),
      },
    );
  });

  db.onRpc("comms_customer_vars", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    return customerVars(ctx.db, String(args.p_shop_id), String(args.p_customer_id));
  });

  db.onRpc("comms_job_vars", (args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    return jobVars(ctx.db, String(args.p_job_id));
  });

  db.onRpc("public_unsubscribe", (args, ctx) => {
    // 0035: only a marketing email's unsubscribe_token (never a message id)
    const msg = ctx.db.table("messages").find((m) =>
      typeof args.p_token === "string" && m.unsubscribe_token === args.p_token &&
      m.direction === "outbound" &&
      m.channel === "email" && m.customer_id !== null &&
      (m.campaign_id !== null || MARKETING_KEYS.includes(String(m.template_key)))
    );
    if (!msg) return false;
    const customers = ctx.db.table("customers");
    for (const c of customers) {
      if (c.id === msg.customer_id && c.shop_id === msg.shop_id) {
        c.email_opted_out_at ??= NOW.toISOString();
        c.email_opt_in = false;
      }
    }
    ctx.db.seed("customers", customers);
    return true;
  });

  db.onRpc("enqueue_due_automations", (_args, ctx) => {
    if (ctx.role !== "service_role") throw new FakeRpcError("42501", "permission denied");
    return 3;
  });

  const numbers = options.twilioNumbers ??
    [{ phone_number: SHOP_NUMBER, sms_url: inboundWebhookUrl(SHOP) }];
  db.http.on("GET", TWILIO_NUMBERS_URL, (_req, match) => {
    const wanted = match.url.searchParams.get("PhoneNumber");
    return jsonResponse({
      incoming_phone_numbers: numbers.filter((n) => n.phone_number === wanted),
    });
  });

  let smsCount = 0;
  db.http.on("POST", TWILIO_MESSAGES_URL, () => {
    smsCount += 1;
    return jsonResponse({ sid: `SM${String(smsCount).padStart(32, "0")}`, status: "queued" }, 201);
  });
  let emailCount = 0;
  db.http.on("POST", RESEND_URL, () => {
    emailCount += 1;
    return jsonResponse({ id: `email-${emailCount}` });
  });

  const logs = memoryLogger();
  const handler = makeHandler({
    env: db.env(options.env),
    fetch: db.http.fetch,
    logger: logs.logger,
    now: () => NOW,
    concurrency: options.concurrency ?? 3,
    ...options.deps,
  });
  return { db, handler, logs };
}

export function message(db: FakeSupabase, id: string): Row {
  const row = db.table("messages").find((m) => m.id === id);
  if (!row) throw new Error(`message ${id} not found`);
  return row;
}
