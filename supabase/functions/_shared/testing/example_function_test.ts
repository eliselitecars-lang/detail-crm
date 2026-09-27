/**
 * End-to-end template for business functions: a miniature "payments"-style
 * function built only from _shared pieces, tested with FakeSupabase + Stripe
 * stubs on ONE FakeFetch. Copy this shape for real functions:
 *
 *   - makeHandler(deps) factory; production does `Deno.serve(makeHandler())`
 *   - createHandler + createActionRouter (JSON actions, strict zod params)
 *   - requireUser + requireShopRole server-side; row -> shop_id -> role
 *   - amounts derived from the database, never from the request
 *   - Stripe call on the shop's connected account with an idempotency key
 */
import { assertEquals } from "@std/assert";
import { z } from "zod";
import { createActionRouter, jsonAction } from "../actions.ts";
import { requireShopRole, requireUser, ROLES } from "../auth.ts";
import type { Env } from "../env.ts";
import { errors } from "../errors.ts";
import { createHandler, type ErrorBody } from "../http.ts";
import type { Logger } from "../log.ts";
import { applicationFeeCents, assertChargeableCents } from "../money.ts";
import { requestNonce, uuid } from "../schemas.ts";
import { idempotencyKey, onAccount, stripeFromEnv } from "../stripe.ts";
import { adminClient } from "../supabase.ts";
import { jsonResponse } from "./fake_fetch.ts";
import { FakeSupabase } from "./fake_supabase.ts";
import { memoryLogger } from "./logger.ts";
import { jsonRequest, responseJson } from "./requests.ts";

interface Deps {
  env?: Env;
  fetch?: typeof fetch;
  logger?: Logger;
}

function makeHandler(deps: Deps = {}) {
  const router = createActionRouter({
    payment_sheet: jsonAction(
      z.object({ invoice_id: uuid, request_nonce: requestNonce }).strict(),
      async (input, ctx) => {
        const admin = adminClient({ env: deps.env, fetch: deps.fetch });
        const caller = await requireUser(ctx.req, { admin });
        const { data: invoice, error } = await admin
          .from("invoices")
          .select("id, shop_id, balance_cents, status")
          .eq("id", input.invoice_id)
          .maybeSingle();
        if (error) throw new Error("invoice lookup failed", { cause: error });
        if (!invoice) throw errors.notFound("Invoice not found.");
        await requireShopRole(admin, caller, invoice.shop_id, ROLES.managerPlus);
        if (invoice.status === "void" || invoice.balance_cents <= 0) {
          throw errors.conflict("This invoice has no balance due.");
        }
        const { data: account } = await admin
          .from("shop_stripe_accounts")
          .select("stripe_account_id, charges_enabled")
          .eq("shop_id", invoice.shop_id)
          .maybeSingle();
        if (!account?.charges_enabled) {
          throw errors.unprocessable("Connect Stripe before taking card payments.");
        }
        const amount = assertChargeableCents(invoice.balance_cents);
        const stripe = stripeFromEnv(ctx.env, { fetch: deps.fetch, maxNetworkRetries: 0 });
        const intent = await stripe.paymentIntents.create(
          {
            amount,
            currency: "usd",
            application_fee_amount: applicationFeeCents(amount, ctx.env.platformFeeBps()) ||
              undefined,
            metadata: { invoice_id: invoice.id, shop_id: invoice.shop_id },
          },
          onAccount(account.stripe_account_id, {
            idempotencyKey: await idempotencyKey(
              "payment_sheet",
              invoice.id,
              amount,
              input.request_nonce,
            ),
          }),
        );
        return { client_secret: intent.client_secret, amount_cents: amount };
      },
    ),
  });
  return createHandler(
    { name: "payments-example", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const INVOICE = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const MANAGER = "10000000-0000-4000-8000-000000000001";
const TECH = "10000000-0000-4000-8000-000000000002";

function setup() {
  const db = new FakeSupabase({
    env: { PLATFORM_FEE_BPS: "100" },
    users: {
      "tok-manager": { id: MANAGER, email: "m@example.com" },
      "tok-tech": { id: TECH, email: "t@example.com" },
    },
    tables: {
      shop_members: [
        {
          id: "m1",
          shop_id: SHOP,
          user_id: MANAGER,
          role: "manager",
          display_name: "M",
          active: true,
        },
        {
          id: "m2",
          shop_id: SHOP,
          user_id: TECH,
          role: "technician",
          display_name: "T",
          active: true,
        },
      ],
      invoices: [{
        id: INVOICE,
        shop_id: SHOP,
        balance_cents: 12_345,
        total_cents: 20_000,
        status: "partially_paid",
      }],
      shop_stripe_accounts: [{
        shop_id: SHOP,
        stripe_account_id: "acct_1ShopAccount0",
        charges_enabled: true,
      }],
    },
  });
  db.http.on("POST", "https://api.stripe.com/v1/payment_intents", (_req, { call }) =>
    jsonResponse({
      id: "pi_1",
      object: "payment_intent",
      amount: Number(call.form.get("amount")),
      client_secret: "pi_1_secret_x",
    }));
  const logs = memoryLogger();
  const handler = makeHandler({ env: db.env(), fetch: db.http.fetch, logger: logs.logger });
  return { db, handler };
}

Deno.test("example function: manager gets a sheet for the DB balance, not a client amount", async () => {
  const { db, handler } = setup();
  const res = await handler(
    jsonRequest(
      "payments",
      { action: "payment_sheet", invoice_id: INVOICE, request_nonce: "nonce-0001" },
      { token: "tok-manager", origin: "https://app.example.com" },
    ),
  );
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { client_secret: "pi_1_secret_x", amount_cents: 12_345 });
  assertEquals(res.headers.get("access-control-allow-origin"), "https://app.example.com");
  const stripeCall = db.http.callsTo("POST", "https://api.stripe.com/v1/payment_intents")[0];
  assertEquals(stripeCall?.form.get("amount"), "12345");
  assertEquals(stripeCall?.form.get("application_fee_amount"), "123");
  assertEquals(stripeCall?.headers.get("stripe-account"), "acct_1ShopAccount0");
  assertEquals(db.requests.every((r) => r.role === "service_role" || r.kind === "auth"), true);
});

Deno.test("example function: a client-sent amount is rejected by the strict schema", async () => {
  const { handler } = setup();
  const res = await handler(
    jsonRequest("payments", {
      action: "payment_sheet",
      invoice_id: INVOICE,
      request_nonce: "nonce-0001",
      amount_cents: 1,
    }, { token: "tok-manager" }),
  );
  assertEquals(res.status, 400);
  assertEquals((await responseJson<ErrorBody>(res)).code, "validation_failed");
});

Deno.test("example function: technicians and signed-out callers are refused", async () => {
  const { db, handler } = setup();
  const body = { action: "payment_sheet", invoice_id: INVOICE, request_nonce: "nonce-0001" };
  const tech = await handler(jsonRequest("payments", body, { token: "tok-tech" }));
  assertEquals([tech.status, (await responseJson<ErrorBody>(tech)).code], [403, "forbidden"]);
  const anon = await handler(jsonRequest("payments", body));
  assertEquals([anon.status, (await responseJson<ErrorBody>(anon)).code], [401, "unauthorized"]);
  assertEquals(db.http.callsTo("POST", "https://api.stripe.com/v1/payment_intents").length, 0);
});

Deno.test("example function: retries reuse the idempotency key; new nonces don't", async () => {
  const { db, handler } = setup();
  const send = (nonce: string) =>
    handler(
      jsonRequest("payments", {
        action: "payment_sheet",
        invoice_id: INVOICE,
        request_nonce: nonce,
      }, {
        token: "tok-manager",
      }),
    );
  for (const nonce of ["nonce-0001", "nonce-0001", "nonce-0002"]) {
    await (await send(nonce)).body?.cancel();
  }
  const keys = db.http.callsTo("POST", "https://api.stripe.com/v1/payment_intents")
    .map((c) => c.headers.get("idempotency-key"));
  assertEquals(keys[0], keys[1]);
  assertEquals(keys[0] === keys[2], false);
});
