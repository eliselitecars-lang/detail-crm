/**
 * stripe-connect — Stripe Connect (Express) onboarding for a shop (SPEC §5).
 * Owner/admin only (SPEC §3: "Stripe Connect ... owner ✓ admin ✓").
 *
 *   create_account_link {shop_id, request_nonce?} -> {url, expires_at, stripe_account_id}
 *       Creates the shop's Express account on first use (stored in
 *       shop_stripe_accounts by service_role) and returns a one-time
 *       onboarding link back to /app/settings/payments?stripe=return|refresh.
 *   refresh_status {shop_id} -> {connected, stripe_account_id, charges_enabled,
 *       payouts_enabled, details_submitted}
 *       Re-reads the account from Stripe and stores its capability flags.
 *   login_link {shop_id, request_nonce?} -> {url}
 *       Express dashboard login link (after onboarding details are submitted).
 *
 * The gateway verifies the JWT (config.toml verify_jwt = true); the function
 * still verifies the caller with Auth and checks the role on the shop.
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import type { Env } from "../_shared/env.ts";
import { errors } from "../_shared/errors.ts";
import { createHandler } from "../_shared/http.ts";
import { isStripeAccountId } from "../_shared/ids.ts";
import { links } from "../_shared/links.ts";
import type { Logger } from "../_shared/log.ts";
import { requestNonce, uuid } from "../_shared/schemas.ts";
import { idempotencyKey, type Stripe, stripeFromEnv } from "../_shared/stripe.ts";
import { adminClient, type SupabaseClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  /** Tests inject FakeFetch (Supabase + Stripe stubs on one fetch). */
  fetch?: typeof fetch;
  logger?: Logger;
}

interface ShopRow {
  id: string;
  name: string;
  slug: string;
  email: string | null;
  website: string | null;
}

interface AccountRow {
  shop_id: string;
  stripe_account_id: string;
  charges_enabled: boolean;
  payouts_enabled: boolean;
  details_submitted: boolean;
}

const ACCOUNT_COLUMNS =
  "shop_id, stripe_account_id, charges_enabled, payouts_enabled, details_submitted";

const shopInput = z.object({ shop_id: uuid }).strict();
const shopNonceInput = z.object({ shop_id: uuid, request_nonce: requestNonce.optional() }).strict();

function dbFailure(what: string, cause: unknown): Error {
  return new Error(`${what} failed`, { cause });
}

async function loadShop(admin: SupabaseClient, shopId: string): Promise<ShopRow> {
  const { data, error } = await admin
    .from("shops")
    .select("id, name, slug, email, website")
    .eq("id", shopId)
    .maybeSingle();
  if (error) throw dbFailure("shops lookup", error);
  if (!data) throw errors.notFound("Shop not found.");
  return data as ShopRow;
}

async function loadAccount(admin: SupabaseClient, shopId: string): Promise<AccountRow | null> {
  const { data, error } = await admin
    .from("shop_stripe_accounts")
    .select(ACCOUNT_COLUMNS)
    .eq("shop_id", shopId)
    .maybeSingle();
  if (error) throw dbFailure("shop_stripe_accounts lookup", error);
  return (data as AccountRow | null) ?? null;
}

/** A public https URL Stripe will accept for business_profile.url, if any. */
export function businessUrl(website: string | null, fallback: string): string | undefined {
  for (const candidate of [website, fallback]) {
    if (!candidate) continue;
    const trimmed = candidate.trim();
    const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
    try {
      const url = new URL(withScheme);
      const local = url.hostname === "localhost" || url.hostname.endsWith(".localhost") ||
        /^(127\.|10\.|192\.168\.|0\.)/.test(url.hostname) || url.hostname === "[::1]";
      if (
        (url.protocol === "https:" || url.protocol === "http:") && !local &&
        url.hostname.includes(".")
      ) {
        return url.toString();
      }
    } catch {
      // not a URL: try the next candidate
    }
  }
  return undefined;
}

function flagsOf(account: Stripe.Account): Pick<
  AccountRow,
  "charges_enabled" | "payouts_enabled" | "details_submitted"
> {
  return {
    charges_enabled: account.charges_enabled === true,
    payouts_enabled: account.payouts_enabled === true,
    details_submitted: account.details_submitted === true,
  };
}

function statusBody(row: AccountRow | null) {
  return {
    connected: row !== null,
    stripe_account_id: row?.stripe_account_id ?? null,
    charges_enabled: row?.charges_enabled ?? false,
    payouts_enabled: row?.payouts_enabled ?? false,
    details_submitted: row?.details_submitted ?? false,
  };
}

/** A one-off key part: the client's nonce (retry-safe) or a fresh random value. */
function oneOff(nonce: string | undefined): string {
  return nonce ?? crypto.randomUUID();
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const admin = (): SupabaseClient => adminClient({ env: deps.env, fetch: deps.fetch });
  const stripeFor = (env: Env): Stripe =>
    deps.fetch
      ? stripeFromEnv(env, { fetch: deps.fetch, maxNetworkRetries: 0 })
      : stripeFromEnv(env);

  const router = createActionRouter({
    create_account_link: jsonAction(shopNonceInput, async (input, ctx) => {
      const db = admin();
      const caller = await requireUser(ctx.req, { admin: db });
      await requireShopRole(db, caller, input.shop_id, ROLES.adminPlus);
      const shop = await loadShop(db, input.shop_id);
      const stripe = stripeFor(ctx.env);
      const baseUrl = ctx.env.appBaseUrl();

      let row = await loadAccount(db, shop.id);
      if (!row) {
        const url = businessUrl(shop.website, links.bookingPage(baseUrl, shop.slug));
        const account = await stripe.accounts.create(
          {
            type: "express",
            country: "US",
            ...(shop.email ? { email: shop.email } : {}),
            business_profile: { name: shop.name, ...(url ? { url } : {}) },
            capabilities: {
              card_payments: { requested: true },
              transfers: { requested: true },
            },
            metadata: { shop_id: shop.id },
          },
          // One account per shop: concurrent/retried first calls get the same one.
          { idempotencyKey: await idempotencyKey("connect_account", shop.id) },
        );
        if (!isStripeAccountId(account.id)) {
          throw new Error("Stripe returned an invalid account id");
        }
        const { error } = await db
          .from("shop_stripe_accounts")
          .upsert(
            { shop_id: shop.id, stripe_account_id: account.id, ...flagsOf(account) },
            { onConflict: "shop_id", ignoreDuplicates: true },
          );
        if (error) throw dbFailure("shop_stripe_accounts insert", error);
        row = await loadAccount(db, shop.id);
        if (!row) throw new Error("shop_stripe_accounts row missing after insert");
        ctx.log.info("stripe_account_created", {
          shop_id: shop.id,
          account: row.stripe_account_id,
        });
      }

      const link = await stripe.accountLinks.create(
        {
          account: row.stripe_account_id,
          type: "account_onboarding",
          refresh_url: links.stripeConnect(baseUrl, "refresh"),
          return_url: links.stripeConnect(baseUrl, "return"),
        },
        {
          idempotencyKey: await idempotencyKey(
            "connect_account_link",
            row.stripe_account_id,
            oneOff(input.request_nonce),
          ),
        },
      );
      return {
        url: link.url,
        expires_at: link.expires_at,
        stripe_account_id: row.stripe_account_id,
      };
    }),

    refresh_status: jsonAction(shopInput, async (input, ctx) => {
      const db = admin();
      const caller = await requireUser(ctx.req, { admin: db });
      await requireShopRole(db, caller, input.shop_id, ROLES.adminPlus);
      const row = await loadAccount(db, input.shop_id);
      if (!row) return statusBody(null);
      const account = await stripeFor(ctx.env).accounts.retrieve(row.stripe_account_id);
      const flags = flagsOf(account);
      const { data, error } = await db
        .from("shop_stripe_accounts")
        .update(flags)
        .eq("shop_id", row.shop_id)
        .eq("stripe_account_id", row.stripe_account_id)
        .select(ACCOUNT_COLUMNS)
        .maybeSingle();
      if (error) throw dbFailure("shop_stripe_accounts update", error);
      return statusBody((data as AccountRow | null) ?? { ...row, ...flags });
    }),

    login_link: jsonAction(shopNonceInput, async (input, ctx) => {
      const db = admin();
      const caller = await requireUser(ctx.req, { admin: db });
      await requireShopRole(db, caller, input.shop_id, ROLES.adminPlus);
      const row = await loadAccount(db, input.shop_id);
      if (!row) {
        throw errors.unprocessable("Connect a Stripe account first.", {
          reason: "stripe_not_connected",
        });
      }
      if (!row.details_submitted) {
        throw errors.unprocessable("Finish Stripe onboarding before opening the dashboard.", {
          reason: "onboarding_incomplete",
        });
      }
      const link = await stripeFor(ctx.env).accounts.createLoginLink(
        row.stripe_account_id,
        {},
        {
          idempotencyKey: await idempotencyKey(
            "connect_login_link",
            row.stripe_account_id,
            oneOff(input.request_nonce),
          ),
        },
      );
      return { url: link.url };
    }),
  });

  return createHandler(
    { name: "stripe-connect", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
