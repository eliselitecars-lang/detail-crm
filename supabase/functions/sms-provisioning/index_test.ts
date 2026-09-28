import { assert, assertEquals, assertMatch } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, type Row } from "../_shared/testing/fake_supabase.ts";
import { responseJson } from "../_shared/testing/requests.ts";
import { numberKind, tollfreeStatus } from "./index.ts";
import {
  API,
  CA_SHOP,
  call,
  created,
  cron,
  fixture,
  HUB,
  MSG,
  PRIMARY_PROFILE,
  SHOP,
  sid,
  twilioError,
  UK_SHOP,
} from "./test_fixtures.ts";

const NUMBER = "+18445550123";
const LOCAL = "+12055550199";
const NONCE = "nonce-0123456789";

function provisionedRow(overrides: Row = {}): Row {
  return {
    phone_number: NUMBER,
    shop_id: SHOP,
    twilio_number_sid: sid("PN"),
    messaging_service_sid: sid("MG"),
    kind: "tollfree",
    verification_status: "not_started",
    verification_sid: null,
    rejection_reason: null,
    business_info: {},
    last_checked_at: null,
    ...overrides,
  };
}

async function expectError(res: Response, status: number, reason?: string): Promise<ErrorBody> {
  const body = await responseJson<ErrorBody>(res);
  assertEquals(res.status, status, JSON.stringify(body));
  if (reason) assertEquals((body.details as { reason?: string })?.reason, reason);
  return body;
}

Deno.test("sms-provisioning: helpers", () => {
  assertEquals(numberKind("+18005550100"), "tollfree");
  assertEquals(numberKind("+18885550100"), "tollfree");
  assertEquals(numberKind("+12055550100"), "local");
  assertEquals(tollfreeStatus("TWILIO_APPROVED"), "approved");
  assertEquals(tollfreeStatus("TWILIO_REJECTED"), "rejected");
  assertEquals(tollfreeStatus("IN_REVIEW"), "in_review");
  assertEquals(tollfreeStatus("PENDING_REVIEW"), "pending");
});

Deno.test("status: owner/admin see the flags and number; others are refused", async () => {
  const { handler } = fixture({ env: { SMS_PROVISIONING_ENABLED: undefined } });
  const res = await handler(call("status", { shop_id: SHOP }, "tok-admin"));
  assertEquals(res.status, 200);
  assertEquals(await responseJson(res), {
    enabled: false,
    isv_enabled: false,
    number: {
      number: null,
      kind: null,
      verification_status: null,
      rejection_reason: null,
      provisioned: false,
    },
  });
  await expectError(await handler(call("status", { shop_id: SHOP }, "tok-manager")), 403);
  await expectError(await handler(call("status", { shop_id: SHOP })), 401);
});

Deno.test("dark by default: every provisioning action is 422 provisioning_disabled", async () => {
  const { db, handler } = fixture({ env: { SMS_PROVISIONING_ENABLED: undefined } });
  const bodies: Array<[string, Record<string, unknown>]> = [
    ["search_numbers", { shop_id: SHOP, kind: "tollfree" }],
    ["purchase_number", { shop_id: SHOP, phone_e164: NUMBER, request_nonce: NONCE }],
  ];
  for (const [action, body] of bodies) {
    await expectError(await handler(call(action, body, "tok-owner")), 422, "provisioning_disabled");
  }
  const refresh = await handler(cron());
  assertEquals(await responseJson(refresh), { enabled: false, checked: 0, updated: 0, failed: 0 });
  assertEquals(db.http.calls.filter((c) => c.url.hostname.includes("twilio")).length, 0);
});

Deno.test("search_numbers: queries the shop country's toll-free or local inventory", async () => {
  const { db, handler } = fixture();
  db.http.on("GET", `${API}/AvailablePhoneNumbers/:country/:type`, () =>
    jsonResponse({
      available_phone_numbers: [
        { phone_number: "+18445550123", locality: null, region: null },
        { phone_number: "+12055550199", locality: "Birmingham", region: "AL" },
        { phone_number: "not-a-number" },
      ],
    }));
  const res = await handler(
    call(
      "search_numbers",
      { shop_id: SHOP, kind: "local", area_code: "205", contains: "55" },
      "tok-admin",
    ),
  );
  assertEquals(res.status, 200);
  assertEquals(await responseJson(res), {
    numbers: [
      { phone_e164: "+18445550123", locality: null, region: null },
      { phone_e164: "+12055550199", locality: "Birmingham", region: "AL" },
    ],
  });
  const url = db.http.calls.find((c) => c.url.pathname.includes("AvailablePhoneNumbers"))?.url;
  assertEquals(url?.pathname.endsWith("/AvailablePhoneNumbers/US/Local.json"), true);
  assertEquals(url?.searchParams.get("AreaCode"), "205");
  assertEquals(url?.searchParams.get("Contains"), "55");
  assertEquals(url?.searchParams.get("SmsEnabled"), "true");

  await handler(call("search_numbers", { shop_id: CA_SHOP, kind: "tollfree" }, "tok-owner"));
  assert(
    db.http.calls.some((c) => c.url.pathname.endsWith("/AvailablePhoneNumbers/CA/TollFree.json")),
  );
  await expectError(
    await handler(call("search_numbers", { shop_id: UK_SHOP, kind: "local" }, "tok-owner")),
    422,
    "unsupported_country",
  );
  await expectError(
    await handler(
      call("search_numbers", { shop_id: SHOP, kind: "local", area_code: "12" }, "tok-owner"),
    ),
    400,
  );
});

function purchaseRoutes(
  db: ReturnType<typeof fixture>["db"],
  options: { buyError?: Response } = {},
) {
  const bought: Row[] = [];
  db.http.on("GET", `${API}/IncomingPhoneNumbers.json`, (_req, match) => {
    const name = match.url.searchParams.get("FriendlyName");
    return jsonResponse({ incoming_phone_numbers: bought.filter((n) => n.friendly_name === name) });
  });
  db.http.on("POST", `${API}/IncomingPhoneNumbers.json`, (_req, match) => {
    if (options.buyError) return options.buyError;
    const number = {
      sid: sid("PN"),
      phone_number: match.call.form.get("PhoneNumber"),
      friendly_name: match.call.form.get("FriendlyName"),
      sms_url: match.call.form.get("SmsUrl"),
    };
    bought.push(number);
    return created(number);
  });
  db.http.on(
    "DELETE",
    `${API}/IncomingPhoneNumbers/:pn`,
    () => new Response(null, { status: 204 }),
  );
  db.http.on("POST", `${MSG}/Services`, () => created({ sid: sid("MG") }));
  db.http.on("POST", `${MSG}/Services/:mg/PhoneNumbers`, () => created({ sid: "PN" }));
  db.http.on("DELETE", `${MSG}/Services/:mg`, () => new Response(null, { status: 204 }));
  return bought;
}

Deno.test("purchase_number: buys with the platform webhook, adds a Messaging Service, records it", async () => {
  const { db, handler, rpc, provisionedOf } = fixture();
  const bought = purchaseRoutes(db);
  const res = await handler(
    call(
      "purchase_number",
      { shop_id: SHOP, phone_e164: NUMBER, request_nonce: NONCE },
      "tok-owner",
    ),
  );
  assertEquals(res.status, 200);
  assertEquals(await responseJson(res), {
    number: {
      number: NUMBER,
      kind: "tollfree",
      verification_status: "not_started",
      rejection_reason: null,
      provisioned: true,
    },
  });
  assertEquals(bought.length, 1);
  assertEquals(
    bought[0]?.sms_url,
    `https://fake-project.supabase.co/functions/v1/messaging?action=twilio_inbound&shop_id=${SHOP}#rc=3&rp=all`,
  );
  assertMatch(String(bought[0]?.friendly_name), new RegExp(`^dcrm-${SHOP}-[0-9a-f]{16}$`));
  const service = db.http.callsTo("POST", `${MSG}/Services`)[0];
  assertEquals(service?.form.get("UseInboundWebhookOnNumber"), "true");
  assertEquals(
    service?.form.get("StatusCallback"),
    "https://fake-project.supabase.co/functions/v1/messaging?action=twilio_status#rc=3&rp=all",
  );
  const attach = db.http.callsTo("POST", `${MSG}/Services/:mg/PhoneNumbers`)[0];
  assertEquals(attach?.form.get("PhoneNumberSid"), bought[0]?.sid);
  assertEquals(
    rpc.record_sms_number?.map((
      r,
    ) => [r.p_phone_e164, r.p_kind, r.p_messaging_service_sid !== null]),
    [
      [NUMBER, "tollfree", false],
      [NUMBER, "tollfree", true],
    ],
  );
  assertMatch(String(provisionedOf(SHOP)?.messaging_service_sid), /^MG/);
  assertEquals(db.table("shops").find((s) => s.id === SHOP)?.sms_from_number, NUMBER);

  // A retry of the same purchase changes nothing and buys nothing.
  const again = await handler(
    call(
      "purchase_number",
      { shop_id: SHOP, phone_e164: NUMBER, request_nonce: NONCE },
      "tok-owner",
    ),
  );
  assertEquals(again.status, 200);
  assertEquals(bought.length, 1);
  // Another number while one is provisioned is refused.
  await expectError(
    await handler(
      call(
        "purchase_number",
        { shop_id: SHOP, phone_e164: LOCAL, request_nonce: "other-nonce-1" },
        "tok-owner",
      ),
    ),
    409,
    "already_has_number",
  );
});

Deno.test("purchase_number: a retry after a failure finds the number it already bought", async () => {
  const { db, handler } = fixture();
  const bought = purchaseRoutes(db);
  const record = db.table("shop_sms_numbers");
  let calls = 0;
  db.onRpc("record_sms_number", (args) => {
    calls += 1;
    // first attempt: the number is bought, then the database write fails
    if (calls === 1) throw new FakeRpcError("08006", "connection lost", { status: 503 });
    const row = {
      phone_number: args.p_phone_e164,
      shop_id: args.p_shop_id,
      twilio_number_sid: args.p_number_sid,
      messaging_service_sid: args.p_messaging_service_sid,
      kind: args.p_kind,
      verification_status: "not_started",
    };
    db.seed("shop_sms_numbers", [
      ...record.filter((n) => n.phone_number !== row.phone_number),
      row,
    ]);
    return row;
  });
  const body = { shop_id: SHOP, phone_e164: NUMBER, request_nonce: NONCE };
  assertEquals((await handler(call("purchase_number", body, "tok-owner"))).status, 500);
  assertEquals(bought.length, 1);
  assertEquals((await handler(call("purchase_number", body, "tok-owner"))).status, 200);
  assertEquals(bought.length, 1, "the retry must not buy a second number");
});

Deno.test("purchase_number: unavailable numbers and lost races", async () => {
  const unavailable = fixture();
  purchaseRoutes(unavailable.db, {
    buyError: twilioError(400, 21422, "PhoneNumber is not available"),
  });
  const body = { shop_id: SHOP, phone_e164: NUMBER, request_nonce: NONCE };
  await expectError(
    await unavailable.handler(call("purchase_number", body, "tok-owner")),
    409,
    "number_unavailable",
  );

  // A concurrent purchase won: the number just bought is released again.
  const race = fixture();
  purchaseRoutes(race.db);
  race.db.onRpc("record_sms_number", () => {
    throw new FakeRpcError("23505", "this shop already has a provisioned number", { status: 409 });
  });
  await expectError(
    await race.handler(call("purchase_number", body, "tok-owner")),
    409,
    "already_has_number",
  );
  assertEquals(race.db.http.callsTo("DELETE", `${API}/IncomingPhoneNumbers/:pn`).length, 1);
});

const TOLLFREE_BUSINESS = {
  legal_name: "Shine Auto Spa LLC",
  website: "https://shine.example",
  address_line1: "12 Oak St",
  city: "Birmingham",
  region: "AL",
  postal_code: "35203",
  country: "US",
  contact_first_name: "Alex",
  contact_last_name: "Kim",
  contact_email: "alex@shine.example",
  contact_phone: "+12055550100",
  use_case_categories: ["ACCOUNT_NOTIFICATIONS", "CUSTOMER_CARE"],
  use_case_summary: "Appointment reminders and job updates for our detailing customers.",
  production_message_sample:
    "Shine Auto Spa: your detail is booked for Jun 2 at 10:00 AM. Reply STOP to opt out.",
  opt_in_type: "WEB_FORM",
  opt_in_image_urls: ["https://shine.example/optin.png"],
  estimated_monthly_volume: "1,000",
};

Deno.test("submit_tollfree_verification: submits to Twilio and records pending", async () => {
  const row = provisionedRow();
  const { db, handler, rpc } = fixture({ numbers: [row] });
  db.http.on(
    "POST",
    `${MSG}/Tollfree/Verifications`,
    () => created({ sid: "HH123", status: "PENDING_REVIEW" }),
  );
  const res = await handler(
    call(
      "submit_tollfree_verification",
      { shop_id: SHOP, business: TOLLFREE_BUSINESS },
      "tok-admin",
    ),
  );
  assertEquals(res.status, 200);
  const form = db.http.callsTo("POST", `${MSG}/Tollfree/Verifications`)[0]?.form;
  assertEquals(form?.get("TollfreePhoneNumberSid"), row.twilio_number_sid);
  assertEquals(form?.getAll("UseCaseCategories"), ["ACCOUNT_NOTIFICATIONS", "CUSTOMER_CARE"]);
  assertEquals(form?.get("NotificationEmail"), "alex@shine.example");
  assertEquals(form?.get("MessageVolume"), "1,000");
  assertEquals(form?.get("ExternalReferenceId"), SHOP);
  const saved = rpc.set_sms_verification?.[0];
  assertEquals([saved?.p_status, saved?.p_verification_sid], ["pending", "HH123"]);
  assertEquals((saved?.p_business_info as { kind: string }).kind, "tollfree");

  // Under review now: a second submission is refused.
  await expectError(
    await handler(
      call(
        "submit_tollfree_verification",
        { shop_id: SHOP, business: TOLLFREE_BUSINESS },
        "tok-admin",
      ),
    ),
    409,
    "verification_in_progress",
  );
});

const EDIT_NOW = new Date("2026-09-27T12:00:00Z");

/** A rejected toll-free verification HH999 as Twilio reports it, plus edit/delete/create routes. */
function rejectedRoutes(twilio: Row | null) {
  const f = fixture({
    numbers: [provisionedRow({ verification_status: "rejected", verification_sid: "HH999" })],
    now: EDIT_NOW,
  });
  f.db.http.on(
    "GET",
    `${MSG}/Tollfree/Verifications/:sid`,
    () =>
      twilio === null
        ? twilioError(404, 20404, "The requested resource was not found")
        : jsonResponse({ sid: "HH999", status: "TWILIO_REJECTED", ...twilio }),
  );
  f.db.http.on(
    "POST",
    `${MSG}/Tollfree/Verifications/:sid`,
    () => jsonResponse({ sid: "HH999", status: "PENDING_REVIEW" }),
  );
  f.db.http.on(
    "DELETE",
    `${MSG}/Tollfree/Verifications/:sid`,
    () => new Response(null, { status: 204 }),
  );
  f.db.http.on(
    "POST",
    `${MSG}/Tollfree/Verifications`,
    () => created({ sid: "HH777", status: "PENDING_REVIEW" }),
  );
  const submit = (body: Record<string, unknown> = {}) =>
    f.handler(
      call(
        "submit_tollfree_verification",
        { shop_id: SHOP, business: TOLLFREE_BUSINESS, ...body },
        "tok-owner",
      ),
    );
  return { ...f, submit };
}

Deno.test("submit_tollfree_verification: a rejected one is edited while Twilio allows it; local numbers are refused", async () => {
  const rejected = rejectedRoutes({
    edit_allowed: true,
    edit_expiration: "2026-10-10T00:00:00Z",
  });
  const res = await rejected.submit({ edit_reason: "Website fixed" });
  assertEquals(res.status, 200);
  const edit = rejected.db.http.callsTo("POST", `${MSG}/Tollfree/Verifications/:sid`)[0];
  assertEquals(edit?.url.pathname, "/v1/Tollfree/Verifications/HH999");
  assertEquals(edit?.form.get("TollfreePhoneNumberSid"), null);
  assertEquals(edit?.form.get("EditReason"), "Website fixed");
  assertEquals(edit?.form.get("BusinessName"), TOLLFREE_BUSINESS.legal_name);
  assertEquals(rejected.db.http.callsTo("DELETE", `${MSG}/Tollfree/Verifications/:sid`).length, 0);
  assertEquals(rejected.db.http.callsTo("POST", `${MSG}/Tollfree/Verifications`).length, 0);
  const saved = rejected.rpc.set_sms_verification?.at(-1);
  assertEquals([saved?.p_status, saved?.p_verification_sid], ["pending", "HH999"]);

  // Without an edit_reason a default one is sent (Twilio asks what changed).
  const again = rejectedRoutes({ edit_allowed: true, edit_expiration: null });
  assertEquals((await again.submit()).status, 200);
  assertMatch(
    again.db.http.callsTo("POST", `${MSG}/Tollfree/Verifications/:sid`)[0]?.form.get(
      "EditReason",
    ) ?? "",
    /\S/,
  );

  const local = fixture({ numbers: [provisionedRow({ phone_number: LOCAL, kind: "local" })] });
  await expectError(
    await local.handler(
      call(
        "submit_tollfree_verification",
        { shop_id: SHOP, business: TOLLFREE_BUSINESS },
        "tok-owner",
      ),
    ),
    422,
    "not_tollfree",
  );
  const none = fixture();
  await expectError(
    await none.handler(
      call(
        "submit_tollfree_verification",
        { shop_id: SHOP, business: TOLLFREE_BUSINESS },
        "tok-owner",
      ),
    ),
    422,
    "no_number",
  );
});

Deno.test("submit_tollfree_verification: a rejection Twilio will not let us edit is replaced by a new verification", async () => {
  for (
    const twilio of [
      { edit_allowed: false, edit_expiration: null },
      // the edit window has passed
      { edit_allowed: true, edit_expiration: "2026-09-20T00:00:00Z" },
    ]
  ) {
    const f = rejectedRoutes(twilio);
    const res = await f.submit({ edit_reason: "Website fixed" });
    assertEquals(res.status, 200, JSON.stringify(twilio));
    assertEquals(f.db.http.callsTo("POST", `${MSG}/Tollfree/Verifications/:sid`).length, 0);
    const deleted = f.db.http.callsTo("DELETE", `${MSG}/Tollfree/Verifications/:sid`)[0];
    assertEquals(deleted?.url.pathname, "/v1/Tollfree/Verifications/HH999");
    const fresh = f.db.http.callsTo("POST", `${MSG}/Tollfree/Verifications`)[0];
    assertEquals(
      fresh?.form.get("TollfreePhoneNumberSid"),
      f.provisionedOf(SHOP)?.twilio_number_sid,
    );
    assertEquals(fresh?.form.get("EditReason"), null);
    const saved = f.rpc.set_sms_verification?.at(-1);
    assertEquals([saved?.p_status, saved?.p_verification_sid], ["pending", "HH777"]);
    assertEquals(f.provisionedOf(SHOP)?.verification_sid, "HH777");
  }

  // Twilio no longer has the old verification: submit a new one.
  const gone = rejectedRoutes(null);
  assertEquals((await gone.submit()).status, 200);
  assertEquals(gone.db.http.callsTo("DELETE", `${MSG}/Tollfree/Verifications/:sid`).length, 0);
  assertEquals(gone.db.http.callsTo("POST", `${MSG}/Tollfree/Verifications`).length, 1);
});

Deno.test("submit_tollfree_verification: a rejection Twilio has since moved on from is recorded, not resubmitted", async () => {
  const f = rejectedRoutes({ status: "IN_REVIEW", edit_allowed: false });
  await expectError(await f.submit(), 409, "verification_in_progress");
  assertEquals(f.provisionedOf(SHOP)?.verification_status, "in_review");
  assertEquals(f.db.http.callsTo("POST", `${MSG}/Tollfree/Verifications/:sid`).length, 0);
  assertEquals(f.db.http.callsTo("POST", `${MSG}/Tollfree/Verifications`).length, 0);
  assertEquals(f.db.http.callsTo("DELETE", `${MSG}/Tollfree/Verifications/:sid`).length, 0);
});

Deno.test("submit_tollfree_verification: Twilio's objections to the details are 422 with its message", async () => {
  const f = fixture({ numbers: [provisionedRow()] });
  f.db.http.on(
    "POST",
    `${MSG}/Tollfree/Verifications`,
    () => twilioError(400, 21605, "Invalid BusinessWebsite: the URL could not be reached"),
  );
  const body = await expectError(
    await f.handler(
      call(
        "submit_tollfree_verification",
        { shop_id: SHOP, business: TOLLFREE_BUSINESS },
        "tok-admin",
      ),
    ),
    422,
    "twilio_rejected_details",
  );
  assertMatch(body.error, /Invalid BusinessWebsite: the URL could not be reached/);
  assertEquals(body.details, {
    reason: "twilio_rejected_details",
    twilio_code: "21605",
    twilio_message: "Invalid BusinessWebsite: the URL could not be reached",
  });
  assertEquals(f.rpc.set_sms_verification?.length, 0);

  // Platform problems stay "try again" upstream errors.
  for (const [status, code] of [[401, 20003], [429, 20429], [500, 20500]] as const) {
    const g = fixture({ numbers: [provisionedRow()] });
    g.db.http.on("POST", `${MSG}/Tollfree/Verifications`, () => twilioError(status, code, "nope"));
    await expectError(
      await g.handler(
        call(
          "submit_tollfree_verification",
          { shop_id: SHOP, business: TOLLFREE_BUSINESS },
          "tok-admin",
        ),
      ),
      502,
    );
  }
});

const A2P_BUSINESS = {
  legal_name: "Shine Auto Spa LLC",
  business_type: "Limited Liability Corporation",
  industry: "AUTOMOTIVE",
  registration_identifier: "EIN",
  registration_number: "12-3456789",
  website: "https://shine.example",
  regions_of_operation: ["USA_AND_CANADA"],
  company_type: "private",
  address_line1: "12 Oak St",
  city: "Birmingham",
  region: "AL",
  postal_code: "35203",
  country: "US",
  email: "alex@shine.example",
  representative: {
    first_name: "Alex",
    last_name: "Kim",
    email: "alex@shine.example",
    phone: "+12055550100",
    business_title: "Owner",
    job_position: "CEO",
  },
};

const A2P_CAMPAIGN = {
  use_case: "CUSTOMER_CARE",
  description:
    "Appointment confirmations, reminders and job status updates for detailing customers.",
  message_flow: "Customers opt in on our online booking form by checking the text messages box.",
  message_samples: [
    "Shine Auto Spa: your detail is confirmed for Jun 2 at 10 AM. Reply STOP to opt out.",
    "Shine Auto Spa: your car is ready for pickup. Reply STOP to opt out.",
  ],
  has_embedded_links: true,
  has_embedded_phone: false,
};

function a2pRoutes(
  db: ReturnType<typeof fixture>["db"],
  options: { evaluation?: string; failTrustProduct?: number; addressError?: Response } = {},
) {
  let trustProductAttempts = 0;
  db.http.on("POST", `${HUB}/CustomerProfiles`, () => created({ sid: sid("BU") }));
  db.http.on("POST", `${HUB}/EndUsers`, () => created({ sid: sid("IT") }));
  db.http.on(
    "POST",
    `${HUB}/CustomerProfiles/:bu/EntityAssignments`,
    () => created({ sid: sid("BV") }),
  );
  db.http.on("POST", `${HUB}/CustomerProfiles/:bu/Evaluations`, () =>
    created({
      status: options.evaluation ?? "compliant",
      results: [{
        passed: false,
        requirement_friendly_name: "Business Information",
        fields: [{ passed: false, friendly_name: "Website URL" }],
      }],
    }));
  db.http.on(
    "POST",
    `${HUB}/CustomerProfiles/:bu`,
    () => jsonResponse({ status: "pending-review" }),
  );
  db.http.on(
    "POST",
    `${API}/Addresses.json`,
    () => options.addressError ?? created({ sid: sid("AD") }),
  );
  db.http.on("POST", `${HUB}/SupportingDocuments`, () => created({ sid: sid("RD") }));
  db.http.on("POST", `${HUB}/TrustProducts`, () => {
    trustProductAttempts += 1;
    if (options.failTrustProduct && trustProductAttempts <= options.failTrustProduct) {
      return twilioError(503, 20500, "Service unavailable");
    }
    return created({ sid: sid("BU") });
  });
  db.http.on(
    "POST",
    `${HUB}/TrustProducts/:bu/EntityAssignments`,
    () => created({ sid: sid("BV") }),
  );
  db.http.on(
    "POST",
    `${HUB}/TrustProducts/:bu/Evaluations`,
    () => created({ status: "compliant", results: [] }),
  );
  db.http.on("POST", `${HUB}/TrustProducts/:bu`, () => jsonResponse({ status: "pending-review" }));
  db.http.on(
    "POST",
    `${MSG}/a2p/BrandRegistrations`,
    () => created({ sid: "BN" + "1".repeat(32), status: "PENDING" }),
  );
}

Deno.test("submit_10dlc: needs the ISV flag, a local number and the primary profile", async () => {
  const off = fixture({ numbers: [provisionedRow({ phone_number: LOCAL, kind: "local" })] });
  await expectError(
    await off.handler(
      call(
        "submit_10dlc",
        { shop_id: SHOP, business: A2P_BUSINESS, campaign: A2P_CAMPAIGN },
        "tok-owner",
      ),
    ),
    422,
    "isv_required",
  );
  const noPrimary = fixture({
    env: { TWILIO_ISV_ENABLED: "true" },
    numbers: [provisionedRow({ phone_number: LOCAL, kind: "local" })],
  });
  const res = await noPrimary.handler(
    call(
      "submit_10dlc",
      { shop_id: SHOP, business: A2P_BUSINESS, campaign: A2P_CAMPAIGN },
      "tok-owner",
    ),
  );
  assertEquals((await expectError(res, 500)).code, "server_misconfigured");
  const tollfree = fixture({
    env: { TWILIO_ISV_ENABLED: "true", TWILIO_PRIMARY_CUSTOMER_PROFILE_SID: PRIMARY_PROFILE },
    numbers: [provisionedRow()],
  });
  await expectError(
    await tollfree.handler(
      call(
        "submit_10dlc",
        { shop_id: SHOP, business: A2P_BUSINESS, campaign: A2P_CAMPAIGN },
        "tok-owner",
      ),
    ),
    422,
    "not_local",
  );
});

Deno.test("submit_10dlc: registers profile, messaging profile and brand; resumes after a failure", async () => {
  const { db, handler, provisionedOf } = fixture({
    env: { TWILIO_ISV_ENABLED: "true", TWILIO_PRIMARY_CUSTOMER_PROFILE_SID: PRIMARY_PROFILE },
    numbers: [provisionedRow({ phone_number: LOCAL, kind: "local" })],
  });
  a2pRoutes(db, { failTrustProduct: 1 });
  const body = { shop_id: SHOP, business: A2P_BUSINESS, campaign: A2P_CAMPAIGN };
  const first = await handler(call("submit_10dlc", body, "tok-owner"));
  assertEquals(first.status, 502);
  assertEquals(db.http.callsTo("POST", `${HUB}/CustomerProfiles`).length, 1);

  const second = await handler(call("submit_10dlc", body, "tok-owner"));
  assertEquals(second.status, 200);
  // resumed: the customer profile and its parts were not created twice
  assertEquals(db.http.callsTo("POST", `${HUB}/CustomerProfiles`).length, 1);
  assertEquals(db.http.callsTo("POST", `${HUB}/EndUsers`).length, 3);
  assertEquals(db.http.callsTo("POST", `${API}/Addresses.json`).length, 1);
  const assigned = db.http.callsTo("POST", `${HUB}/CustomerProfiles/:bu/EntityAssignments`)
    .map((c) => c.form.get("ObjectSid"));
  assertEquals(assigned.length, 4);
  assert(assigned.includes(PRIMARY_PROFILE));
  const business = JSON.parse(
    db.http.callsTo("POST", `${HUB}/EndUsers`)[0]?.form.get("Attributes") ?? "{}",
  );
  assertEquals(business.business_registration_number, "12-3456789");
  assertEquals(business.business_industry, "AUTOMOTIVE");
  const brand = db.http.callsTo("POST", `${MSG}/a2p/BrandRegistrations`)[0]?.form;
  assertMatch(brand?.get("CustomerProfileBundleSid") ?? "", /^BU/);
  assertMatch(brand?.get("A2PProfileBundleSid") ?? "", /^BU/);
  const row = provisionedOf(SHOP);
  assertEquals(row?.verification_status, "pending");
  assertEquals(row?.verification_sid, "BN" + "1".repeat(32));
  const info = row?.business_info as { kind: string; twilio: { brand_sid: string } };
  assertEquals([info.kind, info.twilio.brand_sid], ["10dlc", "BN" + "1".repeat(32)]);
});

Deno.test("submit_10dlc: a non-compliant profile is reported with its issues and abandoned", async () => {
  const { db, handler, provisionedOf } = fixture({
    env: { TWILIO_ISV_ENABLED: "true", TWILIO_PRIMARY_CUSTOMER_PROFILE_SID: PRIMARY_PROFILE },
    numbers: [provisionedRow({ phone_number: LOCAL, kind: "local" })],
  });
  a2pRoutes(db, { evaluation: "noncompliant" });
  const res = await handler(
    call(
      "submit_10dlc",
      { shop_id: SHOP, business: A2P_BUSINESS, campaign: A2P_CAMPAIGN },
      "tok-owner",
    ),
  );
  const body = await expectError(res, 422, "profile_incomplete");
  assertEquals((body.details as { issues: unknown[] }).issues, [
    { requirement: "Business Information", fields: ["Website URL"] },
  ]);
  assertEquals(provisionedOf(SHOP)?.verification_status, "not_started");
  assertEquals((provisionedOf(SHOP)?.business_info as { twilio: unknown }).twilio, {});
});

Deno.test("submit_10dlc: an address Twilio cannot validate is 422 with its message, and the retry resumes", async () => {
  const { db, handler, provisionedOf } = fixture({
    env: { TWILIO_ISV_ENABLED: "true", TWILIO_PRIMARY_CUSTOMER_PROFILE_SID: PRIMARY_PROFILE },
    numbers: [provisionedRow({ phone_number: LOCAL, kind: "local" })],
  });
  a2pRoutes(db, {
    addressError: twilioError(400, 21629, "The address you have provided cannot be validated."),
  });
  const res = await handler(
    call(
      "submit_10dlc",
      { shop_id: SHOP, business: A2P_BUSINESS, campaign: A2P_CAMPAIGN },
      "tok-owner",
    ),
  );
  const body = await expectError(res, 422, "twilio_rejected_details");
  assertEquals((body.details as { twilio_code: string }).twilio_code, "21629");
  assertMatch(body.error, /cannot be validated/);
  // progress so far is kept for the corrected resubmission
  assertEquals(provisionedOf(SHOP)?.verification_status, "not_started");
  assertEquals((provisionedOf(SHOP)?.business_info as { kind: string }).kind, "10dlc");
});

Deno.test("search_numbers: a Twilio 400 about the search is 422, not 'try again'", async () => {
  const { db, handler } = fixture();
  db.http.on(
    "GET",
    `${API}/AvailablePhoneNumbers/:country/:type`,
    () => twilioError(400, 21452, "No phone numbers found for AreaCode 299"),
  );
  const body = await expectError(
    await handler(
      call("search_numbers", { shop_id: SHOP, kind: "local", area_code: "299" }, "tok-admin"),
    ),
    422,
    "twilio_rejected_details",
  );
  assertMatch(body.error, /AreaCode 299/);
});

Deno.test("refresh_status: polls toll-free and 10DLC registrations and records the outcome", async () => {
  const brandSid = "BN" + "2".repeat(32);
  const serviceSid = sid("MG");
  const { db, handler, rpc } = fixture({
    env: { TWILIO_ISV_ENABLED: "true" },
    numbers: [
      provisionedRow({ verification_status: "pending", verification_sid: "HH1" }),
      provisionedRow({
        phone_number: LOCAL,
        shop_id: CA_SHOP,
        kind: "local",
        messaging_service_sid: serviceSid,
        verification_status: "pending",
        verification_sid: brandSid,
        business_info: {
          kind: "10dlc",
          business: A2P_BUSINESS,
          campaign: A2P_CAMPAIGN,
          twilio: { brand_sid: brandSid, customer_profile_sid: "BUx", trust_product_sid: "BUy" },
        },
      }),
      provisionedRow({
        phone_number: "+18775550000",
        shop_id: UK_SHOP,
        verification_status: "approved",
      }),
    ],
  });
  db.http.on(
    "GET",
    `${MSG}/Tollfree/Verifications/:sid`,
    () =>
      jsonResponse({
        sid: "HH1",
        status: "TWILIO_REJECTED",
        rejection_reason: "Opt-in image unreadable",
      }),
  );
  db.http.on(
    "GET",
    `${MSG}/a2p/BrandRegistrations/:sid`,
    () => jsonResponse({ sid: brandSid, status: "APPROVED" }),
  );
  db.http.on(
    "POST",
    `${MSG}/Services/:mg/Compliance/Usa2p`,
    () => created({ sid: "QE" + "3".repeat(32), campaign_status: "PENDING" }),
  );

  const unauthorized = await handler(cron("wrong-secret-wrong-secret-0000"));
  assertEquals(unauthorized.status, 401);

  const res = await handler(cron());
  assertEquals(await responseJson(res), { enabled: true, checked: 2, updated: 2, failed: 0 });
  const tollfree = rpc.set_sms_verification?.find((r) => r.p_shop_id === SHOP);
  assertEquals([tollfree?.p_status, tollfree?.p_rejection_reason], [
    "rejected",
    "Opt-in image unreadable",
  ]);
  const campaign = db.http.callsTo("POST", `${MSG}/Services/:mg/Compliance/Usa2p`)[0];
  assertEquals(campaign?.url.pathname, `/v1/Services/${serviceSid}/Compliance/Usa2p`);
  assertEquals(campaign?.form.get("BrandRegistrationSid"), brandSid);
  assertEquals(campaign?.form.getAll("MessageSamples").length, 2);
  const a2p = rpc.set_sms_verification?.filter((r) => r.p_shop_id === CA_SHOP).at(-1);
  assertEquals([a2p?.p_status, a2p?.p_verification_sid], ["in_review", "QE" + "3".repeat(32)]);

  // next run: the campaign is verified -> approved
  db.http.on(
    "GET",
    `${MSG}/Services/:mg/Compliance/Usa2p/:qe`,
    () => jsonResponse({ sid: "QE" + "3".repeat(32), campaign_status: "VERIFIED" }),
  );
  const next = await responseJson<{ updated: number }>(await handler(cron()));
  assertEquals(next.updated, 1);
  assertEquals(
    rpc.set_sms_verification?.filter((r) => r.p_shop_id === CA_SHOP).at(-1)?.p_status,
    "approved",
  );
});

Deno.test("release_number: owner only; releases the number and its service", async () => {
  const row = provisionedRow();
  const { db, handler, rpc } = fixture({ numbers: [row] });
  db.http.on("DELETE", `${API}/IncomingPhoneNumbers/:pn`, () => jsonResponse({ code: 20404 }, 404));
  db.http.on("DELETE", `${MSG}/Services/:mg`, () => new Response(null, { status: 204 }));
  await expectError(await handler(call("release_number", { shop_id: SHOP }, "tok-admin")), 403);
  const res = await handler(call("release_number", { shop_id: SHOP }, "tok-owner"));
  assertEquals(res.status, 200);
  const out = await responseJson<{ released: boolean; number: { provisioned: boolean } }>(res);
  assertEquals([out.released, out.number.provisioned], [true, false]);
  assertEquals(
    db.http.callsTo("DELETE", `${API}/IncomingPhoneNumbers/:pn`)[0]?.url.pathname.endsWith(
      `${row.twilio_number_sid}.json`,
    ),
    true,
  );
  assertEquals(rpc.release_sms_number?.length, 1);
  const again = await responseJson<{ released: boolean }>(
    await handler(call("release_number", { shop_id: SHOP }, "tok-owner")),
  );
  assertEquals(again.released, false);
});

// ---------------------------------------------------------------------------
// The platform pays for numbers: standing and churn gates
// ---------------------------------------------------------------------------

const DAY = 24 * 60 * 60 * 1000;
const CLOCK = new Date("2026-09-28T12:00:00Z");

function release(daysAgo: number, overrides: Row = {}): Row {
  return {
    id: crypto.randomUUID(),
    phone_number: "+18445550999",
    shop_id: SHOP,
    shop_name: "Shine Co",
    released_at: new Date(CLOCK.getTime() - daysAgo * DAY).toISOString(),
    ...overrides,
  };
}

const twilioCalls = (db: ReturnType<typeof fixture>["db"]) =>
  db.http.calls.filter((c) => c.url.hostname.endsWith("twilio.com"));

Deno.test("purchase_number: only a shop that pays may buy (lapsed 402, trial / past due 422)", async () => {
  const body = { shop_id: SHOP, phone_e164: NUMBER, request_nonce: NONCE };
  const lapsed = fixture({ standing: { [SHOP]: "lapsed" } });
  purchaseRoutes(lapsed.db);
  const refused = await expectError(
    await lapsed.handler(call("purchase_number", body, "tok-owner")),
    402,
    "subscription_inactive",
  );
  assertEquals(refused.code, "payment_required");
  assertEquals(twilioCalls(lapsed.db).length, 0, "nothing is bought or even looked up");

  for (const state of ["trialing", "past_due"]) {
    const f = fixture({ standing: { [SHOP]: state } });
    purchaseRoutes(f.db);
    const err = await expectError(
      await f.handler(call("purchase_number", body, "tok-owner")),
      422,
      "subscription_required",
    );
    assertEquals((err.details as { state?: string }).state, state);
    assertEquals(twilioCalls(f.db).length, 0);
    assertEquals(f.rpc.record_sms_number?.length, 0);
  }

  // Subscribed or comped (billing off also reads active): the number is bought.
  for (const state of ["active", "comped"]) {
    const f = fixture({ standing: { [SHOP]: state } });
    const bought = purchaseRoutes(f.db);
    assertEquals((await f.handler(call("purchase_number", body, "tok-owner"))).status, 200);
    assertEquals(bought.length, 1);
  }
});

Deno.test("purchase_number: resuming an interrupted purchase is not refused by standing", async () => {
  // The number was bought and recorded before the shop lapsed; only the
  // (free) Messaging Service is missing.
  const f = fixture({
    standing: { [SHOP]: "lapsed" },
    numbers: [provisionedRow({ messaging_service_sid: null })],
  });
  const bought = purchaseRoutes(f.db);
  const res = await f.handler(
    call(
      "purchase_number",
      { shop_id: SHOP, phone_e164: NUMBER, request_nonce: NONCE },
      "tok-owner",
    ),
  );
  assertEquals(res.status, 200);
  assertEquals(bought.length, 0);
  assertEquals(f.db.http.callsTo("POST", `${MSG}/Services`).length, 1);
});

Deno.test("purchase_number: buy / release / buy cannot loop (2 releases per 30 days)", async () => {
  const f = fixture({ now: CLOCK });
  const bought = purchaseRoutes(f.db);
  const buy = (phone: string, nonce: string) =>
    f.handler(
      call(
        "purchase_number",
        { shop_id: SHOP, phone_e164: phone, request_nonce: nonce },
        "tok-owner",
      ),
    );
  const giveBack = () => f.handler(call("release_number", { shop_id: SHOP }, "tok-owner"));

  assertEquals((await buy(NUMBER, "nonce-first-0001")).status, 200);
  assertEquals((await giveBack()).status, 200);
  assertEquals((await buy("+18445550124", "nonce-second-001")).status, 200);
  assertEquals((await giveBack()).status, 200);
  assertEquals(f.db.table("sms_number_releases").length, 2);

  const err = await expectError(
    await buy("+18445550125", "nonce-third-0001"),
    429,
    "number_churn_limit",
  );
  assertEquals(err.code, "rate_limited");
  assertEquals(
    (err.details as { retry_at?: string }).retry_at,
    new Date(CLOCK.getTime() + 30 * DAY).toISOString(),
  );
  assertEquals(bought.length, 2, "the third number is never bought");
});

Deno.test("purchase_number: releases older than the window do not count; a found retry is not refused", async () => {
  const old = fixture({
    now: CLOCK,
    releases: [release(31), release(45), release(10)],
  });
  const bought = purchaseRoutes(old.db);
  const body = { shop_id: SHOP, phone_e164: NUMBER, request_nonce: NONCE };
  assertEquals((await old.handler(call("purchase_number", body, "tok-owner"))).status, 200);
  assertEquals(bought.length, 1);

  // Another shop's releases never count toward this one.
  const other = fixture({
    now: CLOCK,
    releases: [release(1, { shop_id: CA_SHOP }), release(2, { shop_id: CA_SHOP })],
  });
  purchaseRoutes(other.db);
  assertEquals((await other.handler(call("purchase_number", body, "tok-owner"))).status, 200);

  // At the limit, a retry that finds the number it already bought still records it.
  const retry = fixture({ now: CLOCK, releases: [release(1), release(2)] });
  const already = purchaseRoutes(retry.db);
  already.push({
    sid: sid("PN"),
    phone_number: NUMBER,
    friendly_name: `dcrm-${SHOP}-${await nonceHash(NONCE)}`,
  });
  assertEquals((await retry.handler(call("purchase_number", body, "tok-owner"))).status, 200);
  assertEquals(retry.db.http.callsTo("POST", `${API}/IncomingPhoneNumbers.json`).length, 0);
  assertEquals(retry.rpc.record_sms_number?.[0]?.p_number_sid, already[0]?.sid);
});

async function nonceHash(nonce: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(nonce));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")
    .slice(0, 16);
}

Deno.test("submit_10dlc: carrier fees need a shop that pays", async () => {
  const f = fixture({
    env: { TWILIO_ISV_ENABLED: "true", TWILIO_PRIMARY_CUSTOMER_PROFILE_SID: PRIMARY_PROFILE },
    numbers: [provisionedRow({ phone_number: LOCAL, kind: "local" })],
    standing: { [SHOP]: "lapsed" },
  });
  await expectError(
    await f.handler(
      call(
        "submit_10dlc",
        { shop_id: SHOP, business: A2P_BUSINESS, campaign: A2P_CAMPAIGN },
        "tok-owner",
      ),
    ),
    402,
    "subscription_inactive",
  );
  assertEquals(twilioCalls(f.db).length, 0);
  assertEquals(f.rpc.set_sms_verification?.length, 0);
});

// ---------------------------------------------------------------------------
// release_worklist
// ---------------------------------------------------------------------------

const GONE_SHOP = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";

/** The platform's Twilio numbers, looked up by PhoneNumber and released by sid. */
function accountNumbers(db: ReturnType<typeof fixture>["db"], numbers: Row[]) {
  db.http.on("GET", `${API}/IncomingPhoneNumbers.json`, (_req, match) => {
    const phone = match.url.searchParams.get("PhoneNumber");
    if (phone === "+18005550500") return twilioError(503, 20500, "Service unavailable");
    return jsonResponse({
      incoming_phone_numbers: numbers.filter((n) => n.phone_number === phone),
    });
  });
  db.http.on(
    "DELETE",
    `${API}/IncomingPhoneNumbers/:pn`,
    () => new Response(null, { status: 204 }),
  );
}

Deno.test("release_worklist: needs the cron secret; an empty worklist never calls Twilio", async () => {
  const f = fixture();
  await expectError(
    await f.handler(cron("wrong-secret-0123456789abcdef", "release_worklist")),
    401,
  );
  await expectError(
    await f.handler(call("release_worklist", {}, "tok-owner")),
    401,
  );
  const res = await f.handler(cron(undefined, "release_worklist"));
  assertEquals(await responseJson(res), {
    checked: 0,
    pending: [],
    released: 0,
    pruned: 0,
    failed: 0,
  });
  assertEquals(twilioCalls(f.db).length, 0);
});

Deno.test("release_worklist: releases deleted shops' self-serve numbers, reports the rest, prunes what is done", async () => {
  const selfServe = release(3, {
    phone_number: "+18445550101",
    shop_id: GONE_SHOP,
    shop_name: "Closed Co",
  });
  const handBound = release(5, {
    phone_number: "+12055550102",
    shop_id: GONE_SHOP,
    shop_name: "Closed Co",
  });
  const recentDone = release(2, { phone_number: "+18445550103" }); // SHOP exists: kept (limit)
  const oldDone = release(40, { phone_number: "+18445550104" });
  const rebound = release(1, { phone_number: "+18445550105", shop_id: GONE_SHOP });
  const outage = release(1, { phone_number: "+18005550500", shop_id: GONE_SHOP });
  const f = fixture({
    now: CLOCK,
    releases: [selfServe, handBound, recentDone, oldDone, rebound, outage],
    numbers: [{ phone_number: "+18445550105", shop_id: CA_SHOP, twilio_number_sid: null }],
  });
  const selfServeSid = sid("PN");
  const handSid = sid("PN");
  accountNumbers(f.db, [
    {
      sid: selfServeSid,
      phone_number: "+18445550101",
      friendly_name: `dcrm-${GONE_SHOP}-0123456789abcdef`,
    },
    { sid: handSid, phone_number: "+12055550102", friendly_name: "Closed Co main line" },
  ]);

  const res = await f.handler(cron(undefined, "release_worklist"));
  assertEquals(res.status, 200);
  const out = await responseJson<Record<string, unknown>>(res);
  assertEquals(out, {
    checked: 6,
    pending: [{
      phone_number: "+12055550102",
      twilio_number_sid: handSid,
      shop_id: GONE_SHOP,
      shop_name: "Closed Co",
      shop_deleted: true,
      released_at: handBound.released_at,
    }],
    released: 1,
    pruned: 3,
    failed: 1,
  });
  const deleted = f.db.http.callsTo("DELETE", `${API}/IncomingPhoneNumbers/:pn`);
  assertEquals(deleted.map((c) => c.url.pathname.endsWith(`/${selfServeSid}.json`)), [true]);
  // Left: the hand-bound number (pending), the failed lookup (retried
  // tomorrow) and SHOP's recent release (counts toward its limit).
  assertEquals(
    f.db.table("sms_number_releases").map((r) => r.phone_number).sort(),
    ["+12055550102", "+18005550500", "+18445550103"],
  );
  assertEquals(f.log.events("sms_numbers_awaiting_release").length, 1);
});
