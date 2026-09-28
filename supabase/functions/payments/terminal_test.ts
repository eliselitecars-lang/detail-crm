import { assert, assertEquals, assertMatch } from "@std/assert";
import { jsonResponse, type Row, stripeErrorBody } from "../_shared/testing/mod.ts";
import { addressHash, terminalAddress } from "./terminal.ts";
import {
  ACCT,
  CUSTOMER,
  errorOf,
  type Fixture,
  fixture,
  type FixtureOptions,
  INVOICE,
  JOB,
  MEMBERS,
  SHOP,
  STRIPE,
} from "./test_fixtures.ts";

const ADDRESS = {
  address_line1: "12 Main St",
  address_line2: "Bay 3",
  city: "Birmingham",
  region: "AL",
  postal_code: "35203",
  country: "US",
};

const location = { action: "terminal_location", shop_id: SHOP };
const token = { action: "terminal_connection_token", shop_id: SHOP };
const intent = { action: "terminal_payment_intent", shop_id: SHOP, invoice_id: INVOICE };

/** A fixture with the shop's address and Stripe Terminal stubs. */
function terminal(options: FixtureOptions = {}): Fixture {
  const f = fixture({ ...options, shop: { ...ADDRESS, ...options.shop } });
  let locations = 0;
  f.db.http.on("POST", `${STRIPE}/terminal/locations`, () => {
    locations++;
    return jsonResponse({ id: `tml_New${locations}`, object: "terminal.location" });
  });
  f.db.http.on(
    "POST",
    `${STRIPE}/terminal/connection_tokens`,
    () => jsonResponse({ object: "terminal.connection_token", secret: "pst_test_secret" }),
  );
  return f;
}

async function storedHash(): Promise<string> {
  return await addressHash(terminalAddress({ id: SHOP, name: "Shine Co", ...ADDRESS }));
}

Deno.test("terminal_location: created on the connected account from the shop address, then reused", async () => {
  const f = terminal();
  const res = await f.call(location, "manager");
  assertEquals(await res.json(), { location_id: "tml_New1" });
  const create = f.stripe("POST", "/terminal/locations")[0];
  assertEquals(create?.headers.get("stripe-account"), ACCT);
  assertMatch(create?.headers.get("idempotency-key") ?? "", /^dcrm:terminal_location:/);
  assertEquals(create?.form.get("display_name"), "Shine Co");
  assertEquals(create?.form.get("address[line1]"), "12 Main St");
  assertEquals(create?.form.get("address[line2]"), "Bay 3");
  assertEquals(create?.form.get("address[city]"), "Birmingham");
  assertEquals(create?.form.get("address[state]"), "AL");
  assertEquals(create?.form.get("address[postal_code]"), "35203");
  assertEquals(create?.form.get("address[country]"), "US");
  assertEquals(create?.form.get("metadata[shop_id]"), SHOP);
  const row = f.db.table("shop_terminal_locations")[0];
  assertEquals([row?.shop_id, row?.stripe_location_id, row?.address_hash], [
    SHOP,
    "tml_New1",
    await storedHash(),
  ]);

  // Same address: the stored location, no Stripe call.
  assertEquals(await (await f.call(location, "owner")).json(), { location_id: "tml_New1" });
  assertEquals(f.stripe("POST", "/terminal/locations").length, 1);
  assertEquals(f.db.table("shop_terminal_locations").length, 1);
});

Deno.test("terminal_location: a changed shop address gets a new location", async () => {
  const f = terminal({
    terminalLocations: [{
      shop_id: SHOP,
      stripe_location_id: "tml_Old",
      address_hash: "0".repeat(64),
    }],
  });
  assertEquals(await (await f.call(location, "admin")).json(), { location_id: "tml_New1" });
  const rows = f.db.table("shop_terminal_locations");
  assertEquals(rows.length, 1);
  assertEquals([rows[0]?.stripe_location_id, rows[0]?.address_hash], [
    "tml_New1",
    await storedHash(),
  ]);
});

Deno.test("terminal_location: a shop without a full address is 422 shop_address_required", async () => {
  for (const missing of ["address_line1", "city", "postal_code", "region"]) {
    const f = terminal({ shop: { [missing]: null } });
    assertEquals((await errorOf(await f.call(location, "manager"))).slice(0, 3), [
      422,
      "unprocessable",
      { reason: "shop_address_required" },
    ], missing);
    assertEquals(f.stripe("POST", "/terminal/locations").length, 0);
  }
  // A state is not required outside the US / Canada / Australia.
  const uk = terminal({ shop: { country: "GB", region: null, postal_code: "SW1A 1AA" } });
  assertEquals((await uk.call(location, "manager")).status, 200);
  assertEquals(uk.stripe("POST", "/terminal/locations")[0]?.form.get("address[state]"), null);
});

Deno.test("terminal_location: Stripe refusing Terminal is 422 terminal_unavailable", async () => {
  const f = terminal();
  f.db.http.on("POST", `${STRIPE}/terminal/locations`, () =>
    jsonResponse(
      stripeErrorBody("invalid_request_error", "Terminal is not enabled for this account."),
      400,
    ));
  assertEquals((await errorOf(await f.call(location, "manager"))).slice(0, 3), [
    422,
    "unprocessable",
    { reason: "terminal_unavailable" },
  ]);
  assertEquals(f.db.table("shop_terminal_locations").length, 0);
  // an address Stripe cannot use is the shop's to fix
  const bad = terminal();
  bad.db.http.on("POST", `${STRIPE}/terminal/locations`, () =>
    jsonResponse(
      stripeErrorBody("invalid_request_error", "Invalid postal code", {
        param: "address[postal_code]",
      }),
      400,
    ));
  assertEquals((await errorOf(await bad.call(location, "manager"))).slice(0, 3), [
    422,
    "unprocessable",
    { reason: "shop_address_invalid" },
  ]);
});

Deno.test("terminal_location / connection_token: who may set up a reader", async () => {
  // technicians only while the shop lets them collect
  const allowed = terminal();
  assertEquals((await allowed.call(location, "tech")).status, 200);
  const refused = terminal({ shop: { techs_can_collect_payments: false } });
  assertEquals((await errorOf(await refused.call(location, "tech")))[0], 403);
  assertEquals((await errorOf(await refused.call(token, "tech")))[0], 403);
  assertEquals((await refused.call(location, "manager")).status, 200);
  // outsiders, anonymous and signed-out callers never
  const f = terminal();
  assertEquals((await errorOf(await f.call(location, "outsider")))[0], 403);
  assertEquals((await errorOf(await f.call(token, "anon")))[0], 401);
  assertEquals((await errorOf(await f.call(token)))[0], 401);
  assertEquals(f.stripe("POST", "/terminal/connection_tokens").length, 0);
  // Stripe must be connected with charges enabled
  const off = terminal({ account: { charges_enabled: false } });
  assertEquals((await errorOf(await off.call(token, "manager"))).slice(0, 3), [
    422,
    "unprocessable",
    { reason: "charges_disabled" },
  ]);
  const none = terminal({ account: null });
  assertEquals((await errorOf(await none.call(location, "manager")))[2], {
    reason: "stripe_not_connected",
  });
});

Deno.test("terminal_connection_token: scoped to the shop's location on the connected account", async () => {
  const f = terminal();
  const res = await f.call(token, "manager");
  assertEquals(await res.json(), {
    secret: "pst_test_secret",
    location_id: "tml_New1",
    stripe_account_id: ACCT,
  });
  const call = f.stripe("POST", "/terminal/connection_tokens")[0];
  assertEquals(call?.headers.get("stripe-account"), ACCT);
  assertEquals(call?.form.get("location"), "tml_New1");
  // single-use tokens: never one of our idempotency keys (a replay would hand back a used token)
  assert(!(call?.headers.get("idempotency-key") ?? "").startsWith("dcrm:"));
  // a second connection reuses the location, with a new token
  await (await f.call(token, "tech")).body?.cancel();
  assertEquals(f.stripe("POST", "/terminal/locations").length, 1);
  assertEquals(f.stripe("POST", "/terminal/connection_tokens").length, 2);
});

Deno.test("terminal_connection_token: a location deleted in Stripe is re-created once", async () => {
  const f = terminal({
    terminalLocations: [{
      shop_id: SHOP,
      stripe_location_id: "tml_Deleted",
      address_hash: await storedHash(),
    }],
  });
  f.db.http.once("POST", `${STRIPE}/terminal/connection_tokens`, () =>
    jsonResponse(
      stripeErrorBody("invalid_request_error", "No such location: 'tml_Deleted'", {
        code: "resource_missing",
        param: "location",
      }),
      400,
    ));
  const res = await f.call(token, "manager");
  assertEquals((await res.json()).location_id, "tml_New1");
  const tokens = f.stripe("POST", "/terminal/connection_tokens");
  assertEquals(tokens.map((c) => c.form.get("location")), ["tml_Deleted", "tml_New1"]);
  assertEquals(f.db.table("shop_terminal_locations")[0]?.stripe_location_id, "tml_New1");
});

Deno.test("terminal_payment_intent: a card_present intent for the balance, recorded pending", async () => {
  const f = terminal();
  const res = await f.call({ ...intent, tip_cents: 500, request_nonce: "tap-0001" }, "manager");
  assertEquals(await res.json(), {
    payment_intent_id: "pi_1New",
    client_secret: "pi_1New_secret_abc",
    amount_cents: 12_345,
    tip_cents: 500,
    currency: "usd",
    stripe_account_id: ACCT,
  });
  const pi = f.stripe("POST", "/payment_intents")[0];
  const form = pi?.form;
  assertEquals(pi?.headers.get("stripe-account"), ACCT);
  assertMatch(pi?.headers.get("idempotency-key") ?? "", /^dcrm:terminal_intent:/);
  assertEquals(form?.get("amount"), "12845");
  assertEquals(form?.get("payment_method_types[0]"), "card_present");
  assertEquals(form?.get("payment_method_types[1]"), null);
  assertEquals(form?.get("capture_method"), "automatic");
  // no saved cards in person
  assertEquals(form?.get("customer"), null);
  // 2.5% platform fee on the amount, never on the tip
  assertEquals(form?.get("application_fee_amount"), "309");
  assertEquals(form?.get("metadata[channel]"), "terminal");
  assertEquals(form?.get("metadata[source]"), "terminal");
  assertEquals(form?.get("metadata[kind]"), "payment");
  assertEquals(form?.get("metadata[invoice_id]"), INVOICE);
  assertEquals(form?.get("metadata[job_id]"), JOB);
  assertEquals(form?.get("metadata[customer_id]"), CUSTOMER);
  assertEquals(form?.get("metadata[tip_cents]"), "500");
  assertEquals(form?.get("metadata[member_id]"), MEMBERS.manager);
  const upsert = f.rpcCalls.find((c) => c.name === "upsert_stripe_payment");
  assertEquals(upsert?.args, {
    p_shop_id: SHOP,
    p_payment_intent_id: "pi_1New",
    p_status: "pending",
    p_amount_cents: 12_345,
    p_tip_cents: 500,
    p_kind: "payment",
    p_method: "card_present",
    p_invoice_id: INVOICE,
    p_customer_id: CUSTOMER,
    p_stripe_method_type: "card_present",
  });
  // no ephemeral key, no customer on the connected account
  assertEquals(f.stripe("POST", "/ephemeral_keys").length, 0);
  assertEquals(f.stripe("POST", "/customers").length, 0);
});

Deno.test("terminal_payment_intent: the same amount rules as payment_sheet", async () => {
  const f = terminal();
  assertEquals(await errorOf(await f.call({ ...intent, amount_cents: 20_000 }, "manager")), [
    422,
    "unprocessable",
    { reason: "amount_exceeds_balance", balance_cents: 12_345 },
  ]);
  assertEquals(
    (await errorOf(await f.call({ ...intent, amount_cents: 1_000, tip_cents: 1_001 }, "manager")))
      .slice(0, 3),
    [422, "unprocessable", { reason: "tip_too_large", max_tip_cents: 1_000 }],
  );
  // clients never send totals
  assertEquals(
    (await errorOf(await f.call({ ...intent, total_cents: 1 }, "manager")))[1],
    "validation_failed",
  );
  assertEquals(f.stripe("POST", "/payment_intents").length, 0);
  // an issued invoice only
  const draft = terminal({ invoice: { status: "draft" } });
  assertEquals((await errorOf(await draft.call(intent, "manager")))[2], { reason: "draft" });
});

Deno.test("terminal_payment_intent: technicians only for assigned jobs, when allowed", async () => {
  const f = terminal();
  assertEquals((await f.call(intent, "tech")).status, 200);
  assertEquals((await errorOf(await f.call(intent, "tech2")))[0], 403);
  const off = terminal({ shop: { techs_can_collect_payments: false } });
  assertEquals((await errorOf(await off.call(intent, "tech")))[0], 403);
  assertEquals(off.stripe("POST", "/payment_intents").length, 0);
});

Deno.test("terminal_payment_intent: ACH still clearing is not charged again", async () => {
  const processing: Row = {
    id: "ffffffff-ffff-4fff-8fff-00000000a0c1",
    shop_id: SHOP,
    invoice_id: INVOICE,
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "payment",
    method: "ach_debit",
    status: "processing",
    amount_cents: 2_345,
    tip_cents: 0,
    refunded_cents: 0,
    stripe_payment_intent_id: "pi_1Ach",
    created_at: new Date().toISOString(),
  };
  const f = terminal({ payments: [processing] });
  const body = await (await f.call(intent, "manager")).json();
  assertEquals(body.amount_cents, 10_000);
  assertEquals(
    (await errorOf(await f.call({ ...intent, amount_cents: 10_001 }, "manager")))[2],
    { reason: "amount_exceeds_balance", balance_cents: 10_000 },
  );
  // fully covered by the clearing debit: 409, nothing created
  const covered = terminal({ payments: [{ ...processing, amount_cents: 12_345 }] });
  assertEquals((await errorOf(await covered.call(intent, "manager")))[2], {
    reason: "payment_in_progress",
  });
  assertEquals(covered.stripe("POST", "/payment_intents").length, 0);
});

Deno.test("terminal_payment_intent: latest attempt wins over an open PaymentSheet (and back)", async () => {
  const sheet: Row = {
    id: "ffffffff-ffff-4fff-8fff-0000000005e1",
    shop_id: SHOP,
    invoice_id: INVOICE,
    job_id: JOB,
    customer_id: CUSTOMER,
    kind: "payment",
    method: "card",
    status: "pending",
    amount_cents: 12_345,
    tip_cents: 0,
    stripe_payment_intent_id: "pi_1Sheet",
    created_at: new Date().toISOString(),
  };
  const f = terminal({
    payments: [sheet],
    intents: {
      pi_1Sheet: {
        status: "requires_payment_method",
        metadata: { shop_id: SHOP, source: "payment_sheet" },
      },
    },
  });
  assertEquals((await f.call(intent, "manager")).status, 200);
  assertEquals(f.stripe("POST", "/payment_intents/pi_1Sheet/cancel").length, 1);
  const cancelled = f.rpcCalls.find((c) =>
    c.name === "upsert_stripe_payment" && c.args.p_payment_intent_id === "pi_1Sheet"
  );
  assertEquals(cancelled?.args.p_status, "cancelled");

  // A reader intent left open is superseded by a new sheet the same way.
  const reader: Row = { ...sheet, method: "card_present", stripe_payment_intent_id: "pi_1Tap" };
  const g = terminal({
    payments: [reader],
    intents: {
      pi_1Tap: {
        status: "requires_payment_method",
        metadata: { shop_id: SHOP, source: "terminal" },
      },
    },
  });
  const sheetRes = await g.call(
    { action: "payment_sheet", shop_id: SHOP, invoice_id: INVOICE },
    "manager",
  );
  assertEquals(sheetRes.status, 200);
  assertEquals(g.stripe("POST", "/payment_intents/pi_1Tap/cancel").length, 1);
  const released = g.rpcCalls.find((c) =>
    c.name === "upsert_stripe_payment" && c.args.p_payment_intent_id === "pi_1Tap"
  );
  assertEquals([released?.args.p_status, released?.args.p_method], ["cancelled", "card_present"]);
});

Deno.test("terminal_payment_intent: card_present not activated is 422 terminal_unavailable", async () => {
  const f = terminal();
  f.db.http.on("POST", `${STRIPE}/payment_intents`, () =>
    jsonResponse(
      stripeErrorBody(
        "invalid_request_error",
        "The payment method type provided: card_present is invalid.",
        { param: "payment_method_types" },
      ),
      400,
    ));
  assertEquals((await errorOf(await f.call(intent, "manager"))).slice(0, 3), [
    422,
    "unprocessable",
    { reason: "terminal_unavailable" },
  ]);
  assertEquals(f.rpcCalls.filter((c) => c.name === "upsert_stripe_payment").length, 0);
});

Deno.test("terminal: pure address rules", () => {
  const address = terminalAddress({ id: SHOP, name: "x", ...ADDRESS, country: "us" });
  assertEquals(address.country, "US");
  assert(!("line2" in terminalAddress({ id: SHOP, name: "x", ...ADDRESS, address_line2: " " })));
});
