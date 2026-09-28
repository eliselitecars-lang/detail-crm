/**
 * Stripe Terminal: Tap to Pay on iPhone and card readers (P-6). The iOS app
 * ships these screens dark (TAP_TO_PAY_ENABLED / TERMINAL_BLUETOOTH_ENABLED)
 * until Apple grants the Tap to Pay entitlement; the server side works as
 * soon as the shop's connected account has Terminal enabled in Stripe.
 *
 *   terminal_location          manager+, or a technician while the shop lets
 *                              technicians collect: the shop's Terminal
 *                              Location (created on first use, re-created
 *                              when the shop address changes)
 *   terminal_connection_token  same callers: a connection token for the
 *                              Terminal SDK, scoped to that location, on the
 *                              connected account
 *   terminal_payment_intent    same callers as payment_sheet (technicians only
 *                              for invoices of jobs assigned to them): a
 *                              card_present PaymentIntent for the invoice
 *
 * Every Terminal call runs on the shop's connected account (Stripe-Account
 * header), so the SDK must be given `stripe_account_id` with the token.
 * Payments are recorded exactly like PaymentSheet payments: a pending
 * card_present row now, settled by the webhook, superseded by a newer
 * attempt, released by cancel_open_payments or the stale-sheet sweep.
 */
import { z } from "zod";
import { sha256Hex } from "../_shared/crypto.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { nonNegativeCents, positiveCents, requestNonce, uuid } from "../_shared/schemas.ts";
import { idempotencyKey, onAccount, type Stripe } from "../_shared/stripe.ts";
import { isStripeError } from "../_shared/stripe_errors.ts";
import { type AccountRow, dbFailure, loadAccount, type Services } from "./lib.ts";
import { openDeviceIntent, requireShopCollector } from "./staff.ts";

export const terminalLocationInput = z.object({ shop_id: uuid }).strict();

export const terminalConnectionTokenInput = z.object({ shop_id: uuid }).strict();

export const terminalPaymentIntentInput = z.object({
  shop_id: uuid,
  invoice_id: uuid,
  amount_cents: positiveCents.optional(),
  tip_cents: nonNegativeCents.optional(),
  request_nonce: requestNonce.optional(),
}).strict();

interface ShopAddress {
  id: string;
  name: string;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  region: string | null;
  postal_code: string | null;
  country: string | null;
}

/** Countries where Stripe requires a state / province on a Terminal location. */
const STATE_REQUIRED = new Set(["US", "CA", "AU"]);

function clean(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

/**
 * The address Stripe needs for a Terminal Location (line1, city, postal
 * code, country; plus the state where Stripe requires one), or 422
 * shop_address_required. Pure, so the rule is unit tested.
 */
export function terminalAddress(shop: ShopAddress): Stripe.Terminal.LocationCreateParams.Address {
  const address = {
    line1: clean(shop.address_line1),
    line2: clean(shop.address_line2),
    city: clean(shop.city),
    state: clean(shop.region),
    postal_code: clean(shop.postal_code),
    country: clean(shop.country)?.toUpperCase(),
  };
  const missing = !address.line1 || !address.city || !address.postal_code || !address.country ||
    (STATE_REQUIRED.has(address.country) && !address.state);
  if (missing || !address.country) {
    throw errors.unprocessable(
      "Add the shop's street address (with city, state and postal code) in shop settings to take in-person payments.",
      { reason: "shop_address_required" },
    );
  }
  return {
    country: address.country,
    line1: address.line1,
    city: address.city,
    postal_code: address.postal_code,
    ...(address.line2 ? { line2: address.line2 } : {}),
    ...(address.state ? { state: address.state } : {}),
  };
}

/** sha256 hex of the address a location was created with (detects address changes). */
export async function addressHash(
  address: Stripe.Terminal.LocationCreateParams.Address,
): Promise<string> {
  return await sha256Hex(JSON.stringify([
    address.line1 ?? "",
    address.line2 ?? "",
    address.city ?? "",
    address.state ?? "",
    address.postal_code ?? "",
    address.country,
  ]));
}

/**
 * Stripe refused a Terminal call for this connected account (Terminal not
 * enabled / not available in its country): 422 terminal_unavailable. Other
 * errors keep the generic Stripe mapping (502 / 503).
 */
function terminalRefusal(err: unknown): HttpError | null {
  if (!isStripeError(err)) return null;
  if (err.type !== "StripeInvalidRequestError" && err.type !== "StripePermissionError") {
    return null;
  }
  return new HttpError(
    "unprocessable",
    "In-person payments are not available for this shop's Stripe account yet. Turn on Terminal in the Stripe dashboard.",
    { details: { reason: "terminal_unavailable" }, cause: err },
  );
}

function isMissingLocation(err: unknown): boolean {
  if (!isStripeError(err) || err.type !== "StripeInvalidRequestError") return false;
  const e = err as { code?: unknown; param?: unknown };
  return e.code === "resource_missing" && (e.param === undefined || e.param === "location");
}

async function loadShopAddress(s: Services, shopId: string): Promise<ShopAddress> {
  const { data, error } = await s.admin
    .from("shops")
    .select("id, name, address_line1, address_line2, city, region, postal_code, country")
    .eq("id", shopId)
    .maybeSingle();
  if (error) throw dbFailure("shops lookup", error);
  if (!data) throw errors.notFound("Shop not found.");
  return data as ShopAddress;
}

interface LocationRow {
  shop_id: string;
  stripe_location_id: string;
  address_hash: string;
}

/**
 * The shop's Terminal Location on its connected account: the stored one
 * while the shop address is unchanged, otherwise a new one (idempotent per
 * shop / account / address), stored via service role. `replace` forces a new
 * one (Stripe no longer has the stored location).
 */
async function ensureLocation(
  s: Services,
  account: AccountRow,
  options: { replace?: boolean } = {},
): Promise<string> {
  const shop = await loadShopAddress(s, account.shop_id);
  const address = terminalAddress(shop);
  const hash = await addressHash(address);
  const { data, error } = await s.admin
    .from("shop_terminal_locations")
    .select("shop_id, stripe_location_id, address_hash")
    .eq("shop_id", account.shop_id)
    .maybeSingle();
  if (error) throw dbFailure("shop_terminal_locations lookup", error);
  const stored = data as LocationRow | null;
  if (stored && stored.address_hash === hash && !options.replace) {
    return stored.stripe_location_id;
  }

  let location: Stripe.Terminal.Location;
  try {
    location = await s.stripe.terminal.locations.create(
      {
        display_name: shop.name.trim().slice(0, 1000) || "Shop",
        address,
        metadata: { shop_id: account.shop_id },
      },
      onAccount(account.stripe_account_id, {
        idempotencyKey: await idempotencyKey(
          "terminal_location",
          account.shop_id,
          account.stripe_account_id,
          hash,
          options.replace ? `after:${stored?.stripe_location_id ?? "none"}` : "first",
        ),
      }),
    );
  } catch (err) {
    const e = err as { param?: unknown };
    if (isStripeError(err) && typeof e.param === "string" && e.param.startsWith("address")) {
      throw new HttpError(
        "unprocessable",
        "Stripe could not use the shop's address for in-person payments. Check it in shop settings.",
        { details: { reason: "shop_address_invalid" }, cause: err },
      );
    }
    throw terminalRefusal(err) ?? err;
  }
  if (!/^tml_[A-Za-z0-9]+$/.test(location.id)) {
    throw new Error("Stripe returned an unexpected Terminal location id");
  }
  const saved = await s.admin
    .from("shop_terminal_locations")
    .upsert(
      { shop_id: account.shop_id, stripe_location_id: location.id, address_hash: hash },
      { onConflict: "shop_id" },
    );
  if (saved.error) throw dbFailure("shop_terminal_locations upsert", saved.error);
  s.log.info("terminal_location_created", {
    shop_id: account.shop_id,
    location: location.id,
    replaced: stored?.stripe_location_id ?? null,
  });
  return location.id;
}

export async function terminalLocation(
  s: Services,
  req: Request,
  input: z.output<typeof terminalLocationInput>,
): Promise<{ location_id: string }> {
  await requireShopCollector(s, req, input.shop_id);
  const account = await loadAccount(s.admin, input.shop_id);
  return { location_id: await ensureLocation(s, account) };
}

export async function terminalConnectionToken(
  s: Services,
  req: Request,
  input: z.output<typeof terminalConnectionTokenInput>,
): Promise<{ secret: string; location_id: string; stripe_account_id: string }> {
  await requireShopCollector(s, req, input.shop_id);
  const account = await loadAccount(s.admin, input.shop_id);
  let locationId = await ensureLocation(s, account);
  let token: Stripe.Terminal.ConnectionToken;
  try {
    token = await createToken(s, account, locationId);
  } catch (err) {
    // Deleted in the Stripe dashboard: make a new one once.
    if (!isMissingLocation(err)) throw terminalRefusal(err) ?? err;
    locationId = await ensureLocation(s, account, { replace: true });
    try {
      token = await createToken(s, account, locationId);
    } catch (retryErr) {
      throw terminalRefusal(retryErr) ?? retryErr;
    }
  }
  if (!token.secret) throw new Error("Stripe returned a connection token without a secret");
  return {
    secret: token.secret,
    location_id: locationId,
    stripe_account_id: account.stripe_account_id,
  };
}

async function createToken(
  s: Services,
  account: AccountRow,
  locationId: string,
): Promise<Stripe.Terminal.ConnectionToken> {
  // No idempotency key: every SDK connection needs a fresh, single-use token.
  return await s.stripe.terminal.connectionTokens.create(
    { location: locationId },
    onAccount(account.stripe_account_id),
  );
}

export async function terminalPaymentIntent(
  s: Services,
  req: Request,
  input: z.output<typeof terminalPaymentIntentInput>,
): Promise<Record<string, unknown>> {
  let opened;
  try {
    opened = await openDeviceIntent(s, req, input, "terminal");
  } catch (err) {
    // card_present not activated on the connected account
    const param = (err as { param?: unknown }).param;
    if (isStripeError(err) && param === "payment_method_types") {
      throw terminalRefusal(err) ?? err;
    }
    throw err;
  }
  return {
    payment_intent_id: opened.intent.id,
    client_secret: opened.intent.client_secret,
    amount_cents: opened.amount,
    tip_cents: opened.tip,
    currency: opened.shop.currency,
    stripe_account_id: opened.account.stripe_account_id,
  };
}
