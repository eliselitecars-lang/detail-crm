import { assertEquals } from "@std/assert";
import { jsonResponse, type Row } from "../_shared/testing/mod.ts";
import { confirmsName } from "./shop_delete.ts";
import {
  ACCT,
  CUSTOMER,
  errorOf,
  fixture,
  type FixtureOptions,
  INVOICE,
  JOB,
  MEMBERSHIP,
  NOW,
  PLAN,
  SHOP,
  STRIPE,
} from "./test_fixtures.ts";

const del = { action: "delete_shop", shop_id: SHOP, confirm_name: "  shine CO " };
const SUB = "sub_1Billing";
const OTHER_MEMBERSHIP = "88888888-8888-4888-8888-000000000002";

function membership(extra: Row): Row {
  return {
    id: OTHER_MEMBERSHIP,
    shop_id: SHOP,
    plan_id: PLAN,
    customer_id: CUSTOMER,
    vehicle_id: null,
    status: "incomplete",
    stripe_subscription_id: null,
    cancel_at_period_end: false,
    current_period_end: null,
    ...extra,
  };
}

function session(id: string, metadata: Row, mode = "payment"): Row {
  return {
    id,
    object: "checkout.session",
    status: "open",
    mode,
    customer: "cus_1Saved",
    metadata: { shop_id: SHOP, ...metadata },
  };
}

/** A shop with a billing membership, an incomplete one, open links and an abandoned sheet. */
function busyShop(extra: FixtureOptions = {}) {
  const f = fixture({
    customer: { stripe_customer_id: "cus_1Saved" },
    membership: {
      status: "active",
      stripe_subscription_id: SUB,
      current_period_end: "2026-10-27T12:00:00.000Z",
    },
    sessions: [
      session("cs_1Invoice", { invoice_id: INVOICE, kind: "payment" }),
      session("cs_1Deposit", { job_id: JOB, kind: "deposit" }),
      session("cs_1Membership", { membership_id: OTHER_MEMBERSHIP }, "subscription"),
      // Created by the owner in the Express dashboard: not the CRM's.
      { ...session("cs_1Dashboard", {}), metadata: {} },
    ],
    payments: [{
      id: "ffffffff-ffff-4fff-8fff-000000000101",
      shop_id: SHOP,
      invoice_id: INVOICE,
      job_id: JOB,
      customer_id: CUSTOMER,
      kind: "payment",
      method: "card",
      status: "pending",
      amount_cents: 12_345,
      tip_cents: 0,
      refunded_cents: 0,
      stripe_payment_intent_id: "pi_1Sheet",
      created_at: new Date(NOW - 5 * 60_000).toISOString(),
    }],
    intents: {
      pi_1Sheet: {
        status: "requires_payment_method",
        metadata: { shop_id: SHOP, source: "payment_sheet" },
      },
    },
    ...extra,
  });
  f.db.seed("memberships", [...f.db.table("memberships"), membership({})]);
  return f;
}

Deno.test("delete_shop: the name check is trimmed and case-insensitive", () => {
  assertEquals(confirmsName("  shine CO ", "Shine Co"), true);
  assertEquals(confirmsName("Shine", "Shine Co"), false);
  assertEquals(confirmsName("", "Shine Co"), false);
});

Deno.test("delete_shop: billing is cancelled, links expired, sheets released, then the shop is deleted", async () => {
  const f = busyShop();
  const res = await f.call(del, "owner");
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    deleted: true,
    memberships_cancelled: 2,
    sessions_expired: 3,
    platform_subscription_cancelled: false,
  });

  // The billing membership's subscription is cancelled now, on the shop's account.
  const cancel = f.stripe("DELETE", `/subscriptions/${SUB}`)[0];
  assertEquals(cancel?.headers.get("stripe-account"), ACCT);
  assertEquals(
    cancel?.headers.get("idempotency-key")?.startsWith("dcrm:membership_shop_delete:"),
    true,
  );
  const sync = f.rpcCalls.find((c) => c.name === "sync_stripe_subscription")?.args;
  assertEquals([sync?.p_subscription_id, sync?.p_status, sync?.p_membership_id], [
    SUB,
    "cancelled",
    MEMBERSHIP,
  ]);
  // The never-billed membership is cancelled directly.
  assertEquals(
    f.db.table("memberships").find((m) => m.id === OTHER_MEMBERSHIP)?.status,
    "cancelled",
  );
  // Every CRM link is expired; the dashboard's own session is left alone.
  assertEquals(
    f.sessions.map((x) => [x.id, x.status]),
    [
      ["cs_1Invoice", "expired"],
      ["cs_1Deposit", "expired"],
      ["cs_1Membership", "expired"],
      ["cs_1Dashboard", "open"],
    ],
  );
  // The abandoned sheet is cancelled and recorded.
  assertEquals(f.intents.pi_1Sheet?.status, "canceled");
  assertEquals(
    f.rpcCalls.filter((c) =>
      c.name === "upsert_stripe_payment" && c.args.p_payment_intent_id === "pi_1Sheet"
    ).map((c) => c.args.p_status),
    ["cancelled"],
  );
  assertEquals(f.db.table("shops").some((s) => s.id === SHOP), false);
  // The Connect account is never touched (the owner keeps payouts).
  assertEquals(f.stripeCalls().some((c) => c.url.pathname.startsWith("/v1/accounts")), false);
  assertEquals(f.logs.events("shop_deleted").length, 1);
});

// ---------------------------------------------------------------------------
// The shop's own platform subscription (shop_billing, 0100)
// ---------------------------------------------------------------------------

const PLATFORM_SUB = "sub_1Platform";

function billedShop(extra: FixtureOptions = {}) {
  const f = busyShop(extra);
  f.db.seed("shop_billing", [{
    shop_id: SHOP,
    stripe_customer_id: "cus_1PlatformShop",
    stripe_subscription_id: PLATFORM_SUB,
    status: "active",
  }]);
  return f;
}

function stripeError(status: number, type: string, message: string, code?: string) {
  return () => jsonResponse({ error: { type, message, ...(code ? { code } : {}) } }, status);
}

Deno.test("delete_shop: the shop's platform subscription is cancelled first, on the platform account", async () => {
  const f = billedShop();
  const res = await f.call(del, "owner");
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    deleted: true,
    memberships_cancelled: 2,
    sessions_expired: 3,
    platform_subscription_cancelled: true,
  });
  const cancel = f.stripe("DELETE", `/subscriptions/${PLATFORM_SUB}`);
  assertEquals(cancel.length, 1);
  // The platform account itself: never a connected account.
  assertEquals(cancel[0]?.headers.get("stripe-account"), null);
  assertEquals(
    cancel[0]?.headers.get("idempotency-key")?.startsWith(
      "dcrm:platform_subscription_shop_delete:",
    ),
    true,
  );
  // Before any link is expired or membership cancelled.
  const calls = f.stripeCalls();
  const at = (path: string, method: string) =>
    calls.findIndex((c) => c.method === method && c.url.pathname === `/v1${path}`);
  const platform = at(`/subscriptions/${PLATFORM_SUB}`, "DELETE");
  assertEquals(platform < at("/checkout/sessions/cs_1Invoice/expire", "POST"), true);
  assertEquals(platform < at(`/subscriptions/${SUB}`, "DELETE"), true);
  assertEquals(f.logs.events("platform_subscription_cancelled")[0]?.subscription, PLATFORM_SUB);
  assertEquals(f.logs.events("shop_deleted")[0]?.platform_subscription_cancelled, true);
  assertEquals(f.db.table("shops").some((x) => x.id === SHOP), false);
});

Deno.test("delete_shop: a platform subscription already ended or gone in Stripe is fine", async () => {
  // Stripe refuses a second cancel; the subscription reads canceled.
  const ended = billedShop({ subscriptions: { [PLATFORM_SUB]: "canceled" } });
  ended.db.http.once(
    "DELETE",
    `${STRIPE}/subscriptions/${PLATFORM_SUB}`,
    stripeError(400, "invalid_request_error", "This subscription is already canceled."),
  );
  const a = await ended.call(del, "owner");
  assertEquals(a.status, 200);
  assertEquals((await a.json()).platform_subscription_cancelled, false);
  assertEquals(
    ended.stripe("GET", `/subscriptions/${PLATFORM_SUB}`)[0]?.headers.get("stripe-account"),
    null,
  );
  assertEquals(ended.db.table("shops").some((x) => x.id === SHOP), false);

  // Stripe no longer has it.
  const gone = billedShop();
  gone.db.http.once(
    "DELETE",
    `${STRIPE}/subscriptions/${PLATFORM_SUB}`,
    stripeError(404, "invalid_request_error", "No such subscription", "resource_missing"),
  );
  const b = await gone.call(del, "owner");
  assertEquals(b.status, 200);
  assertEquals((await b.json()).platform_subscription_cancelled, false);
  assertEquals(gone.db.table("shops").some((x) => x.id === SHOP), false);

  // No platform subscription at all (never subscribed, or billing off).
  const none = busyShop();
  none.db.seed("shop_billing", [{ shop_id: SHOP, stripe_subscription_id: null, status: "none" }]);
  const c = await none.call(del, "owner");
  assertEquals((await c.json()).platform_subscription_cancelled, false);
  assertEquals(none.stripe("DELETE", `/subscriptions/${PLATFORM_SUB}`).length, 0);
});

Deno.test("delete_shop: a Stripe failure cancelling the platform subscription is 502 and changes nothing", async () => {
  for (
    const failure of [
      stripeError(500, "api_error", "Something went wrong on Stripe's end."),
      // a refusal that is not "already canceled": the subscription is still live
      stripeError(400, "invalid_request_error", "This request cannot be processed right now."),
    ]
  ) {
    const f = billedShop();
    f.db.http.once("DELETE", `${STRIPE}/subscriptions/${PLATFORM_SUB}`, failure);
    const res = await f.call(del, "owner");
    const body = await res.json();
    assertEquals([res.status, body.code, body.details], [502, "upstream_error", {
      reason: "platform_subscription_cancel_failed",
    }]);
    assertEquals(
      body.error,
      "The shop's subscription could not be cancelled, so the shop was not deleted. " +
        "Try again in a moment.",
    );
    // Nothing else changed: links open, memberships and their subscriptions
    // untouched, the shop and its billing row still there.
    assertEquals(f.stripe("POST", "/checkout/sessions/:id/expire").length, 0);
    assertEquals(f.stripe("DELETE", `/subscriptions/${SUB}`).length, 0);
    assertEquals(f.db.table("memberships").every((m) => m.status !== "cancelled"), true);
    assertEquals(f.rpcCalls.some((c) => c.name === "sync_stripe_subscription"), false);
    assertEquals(f.db.table("shops").some((x) => x.id === SHOP), true);
    assertEquals(f.db.table("shop_billing")[0]?.stripe_subscription_id, PLATFORM_SUB);
    assertEquals(f.logs.events("shop_deleted").length, 0);
  }
});

Deno.test("delete_shop: money still processing keeps the platform subscription too", async () => {
  const f = billedShop({
    intents: {
      pi_1Sheet: { status: "processing", metadata: { shop_id: SHOP, source: "payment_sheet" } },
    },
  });
  assertEquals((await errorOf(await f.call(del, "owner")))[2], { reason: "payment_in_progress" });
  assertEquals(f.stripe("DELETE", "/subscriptions/:id").length, 0);
});

Deno.test("delete_shop: a shop without Stripe Connect still cancels its platform subscription", async () => {
  const f = fixture({ account: null });
  f.db.seed("shop_billing", [{
    shop_id: SHOP,
    stripe_subscription_id: PLATFORM_SUB,
    status: "trialing",
  }]);
  const res = await f.call({ ...del, confirm_name: "Shine Co" }, "owner");
  assertEquals((await res.json()).platform_subscription_cancelled, true);
  // Only the platform call: nothing on a connected account.
  assertEquals(f.stripeCalls().map((c) => [c.method, c.url.pathname]), [[
    "DELETE",
    `/v1/subscriptions/${PLATFORM_SUB}`,
  ]]);
  assertEquals(f.stripeCalls()[0]?.headers.get("stripe-account"), null);
});

Deno.test("delete_shop: money still processing refuses the deletion before anything changes", async () => {
  const f = busyShop({
    intents: {
      pi_1Sheet: { status: "processing", metadata: { shop_id: SHOP, source: "payment_sheet" } },
    },
  });
  assertEquals((await errorOf(await f.call(del, "owner"))).slice(0, 3), [
    409,
    "conflict",
    { reason: "payment_in_progress" },
  ]);
  assertEquals(f.stripe("DELETE", "/subscriptions/:id").length, 0);
  assertEquals(f.stripe("POST", "/checkout/sessions/:id/expire").length, 0);
  assertEquals(f.db.table("shops").some((s) => s.id === SHOP), true);
  assertEquals(f.db.table("memberships").every((m) => m.status !== "cancelled"), true);
});

Deno.test("delete_shop: a pay link paid at the last moment is 409 payment_in_progress", async () => {
  const f = busyShop();
  f.db.http.once("POST", `${STRIPE}/checkout/sessions/cs_1Invoice/expire`, () => {
    const paid = f.sessions.find((x) => x.id === "cs_1Invoice");
    if (paid) paid.status = "complete";
    return jsonResponse(
      { error: { type: "invalid_request_error", message: "Only open sessions can be expired." } },
      400,
    );
  });
  assertEquals((await errorOf(await f.call(del, "owner")))[2], { reason: "payment_in_progress" });
  assertEquals(f.db.table("shops").some((s) => s.id === SHOP), true);
});

Deno.test("delete_shop: a subscription Stripe no longer has is still recorded cancelled", async () => {
  const f = busyShop();
  f.db.http.once("DELETE", `${STRIPE}/subscriptions/${SUB}`, () =>
    jsonResponse(
      {
        error: {
          type: "invalid_request_error",
          code: "resource_missing",
          message: "No such subscription",
        },
      },
      404,
    ));
  const res = await f.call(del, "owner");
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(
    f.rpcCalls.find((c) => c.name === "sync_stripe_subscription")?.args.p_status,
    "cancelled",
  );
});

Deno.test("delete_shop: a shop without Stripe is deleted without Stripe calls", async () => {
  const f = fixture({ account: null });
  const res = await f.call({ ...del, confirm_name: "Shine Co" }, "owner");
  assertEquals(await res.json(), {
    deleted: true,
    memberships_cancelled: 1,
    sessions_expired: 0,
    platform_subscription_cancelled: false,
  });
  assertEquals(f.stripeCalls().length, 0);
  assertEquals(f.db.table("memberships").find((m) => m.id === MEMBERSHIP)?.status, "cancelled");
});

Deno.test("delete_shop: owner only, and the typed name must match", async () => {
  const f = busyShop();
  for (const who of ["admin", "manager", "tech", "outsider"] as const) {
    assertEquals((await errorOf(await f.call(del, who)))[1], "forbidden", who);
  }
  assertEquals((await errorOf(await f.call(del, "none")))[1], "unauthorized");
  assertEquals(
    (await errorOf(await f.call({ ...del, confirm_name: "Shine" }, "owner"))).slice(0, 3),
    [422, "unprocessable", { reason: "name_mismatch" }],
  );
  assertEquals(
    (await errorOf(await f.call({ action: "delete_shop", shop_id: SHOP }, "owner")))[1],
    "validation_failed",
  );
  assertEquals(f.stripeCalls().length, 0);
  assertEquals(f.db.table("shops").some((s) => s.id === SHOP), true);
});

Deno.test("delete_shop: the database guard (55000) is 409 payment_in_progress", async () => {
  const f = fixture({ account: null });
  f.db.http.once(
    "DELETE",
    "https://fake-project.supabase.co/rest/v1/shops",
    () =>
      jsonResponse({
        code: "55000",
        message: "a card payment is in progress for this shop",
        details: null,
        hint: null,
      }, 400),
  );
  assertEquals(await errorOf(await f.call({ ...del, confirm_name: "shine co" }, "owner")), [
    409,
    "conflict",
    { reason: "payment_in_progress" },
  ]);
});
