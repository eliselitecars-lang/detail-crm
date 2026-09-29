/**
 * erase_customer (OWNER / ADMIN) — a customer's deletion request (0125).
 * The database decides what happens to the record (erase_customer RPC,
 * service role): deleted when nothing of accounting references it,
 * anonymised in place otherwise (money rows keep their amounts), together
 * with every duplicate merged into it. This action first closes what Stripe
 * still holds for the person on the shop's connected account, because the
 * RPC refuses while any of it is open:
 *
 *   {confirm: false} (default)  the preview: the RPC's dry run, nothing
 *                               changes and Stripe is not called:
 *                               {dry_run: true, mode, erased,
 *                                membership_active, payments_in_progress,
 *                                open_checkouts, saved_cards}
 *   {confirm: true}             1. dry run: an active membership (it still
 *                                  bills the card) refuses with 409
 *                                  membership_active before anything changes;
 *                               2. the customers' unsettled card attempts are
 *                                  settled (unconfirmed PaymentSheets / Tap to
 *                                  Pay intents cancelled, money that landed
 *                                  recorded); money still moving (an intent
 *                                  processing, an ACH debit clearing) refuses
 *                                  with 409 payment_in_progress;
 *                               3. every open Checkout Session of theirs is
 *                                  expired and its hold released (a page that
 *                                  was just paid: 409 payment_in_progress);
 *                               4. every saved card is detached in Stripe and
 *                                  removed from the CRM;
 *                               5. their Stripe Customers are deleted on the
 *                                  connected account (one another CRM customer
 *                                  still uses is left alone and logged);
 *                               6. erase_customer runs, which also clears
 *                                  stripe_customer_id and portal_user_id.
 *                               -> {erased: true, mode: 'deleted' |
 *                                  'anonymised', payments_cancelled,
 *                                  sessions_expired, cards_removed,
 *                                  stripe_customers_deleted}
 *
 * The RPC's refusals (55000 HINT membership_active / payment_in_progress /
 * checkout_open / saved_cards: something opened meanwhile) answer 409 with
 * that reason; retrying is safe (every step is idempotent). A shop without
 * Stripe skips steps 2-5. An already-erased customer answers mode
 * 'anonymised' again without changing anything.
 */
import { z } from "zod";
import { requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { uuid } from "../_shared/schemas.ts";
import { idempotencyKey, onAccount } from "../_shared/stripe.ts";
import { releaseCustomerPages } from "./checkout_holds.ts";
import {
  type AccountRow,
  type DbError,
  dbFailure,
  findAccount,
  isInvalidRequest,
  paymentInProgress,
  refusedWith,
  rpcError,
  type Services,
} from "./lib.ts";
import { settleCustomers } from "./settle.ts";
import { detachCard, removeCardRow } from "./staff.ts";

export const eraseCustomerInput = z.object({
  shop_id: uuid,
  customer_id: uuid,
  /** false / absent: preview only (the dry run); true: erase. */
  confirm: z.boolean().optional(),
}).strict();

/** erase_customer's dry run (0125). */
export interface ErasePreview {
  dry_run: true;
  mode: "deleted" | "anonymised";
  erased: boolean;
  membership_active: boolean;
  payments_in_progress: number;
  open_checkouts: number;
  saved_cards: number;
}

export interface EraseResult {
  erased: true;
  mode: "deleted" | "anonymised";
  payments_cancelled: number;
  sessions_expired: number;
  cards_removed: number;
  stripe_customers_deleted: number;
}

/** The RPC's 55000 HINTs, worded for staff. */
const REFUSALS: Record<string, string> = {
  membership_active:
    "This customer has a membership that is still active. Cancel it first, then delete the customer.",
  payment_in_progress:
    "A payment from this customer is still going through. Try again once it has finished.",
  checkout_open:
    "A card payment page for this customer was opened meanwhile. Try again in a moment.",
  saved_cards: "A card was saved for this customer meanwhile. Try again in a moment.",
};

function refusal(reason: keyof typeof REFUSALS, cause?: unknown): HttpError {
  return new HttpError("conflict", REFUSALS[reason] ?? "This customer can't be deleted yet.", {
    details: { reason },
    ...(cause === undefined ? {} : { cause }),
  });
}

function eraseRpcError(error: DbError): Error {
  for (const reason of Object.keys(REFUSALS)) {
    if (refusedWith(error, "55000", reason)) return refusal(reason, error);
  }
  // Also a customer erased meanwhile answers 55000 HINT customer_erased.
  return rpcError("erase_customer", error, { notFound: "Customer not found." });
}

async function eraseRpc(
  s: Services,
  input: z.output<typeof eraseCustomerInput>,
  actor: string,
  dryRun: boolean,
): Promise<Record<string, unknown>> {
  const { data, error } = await s.admin.rpc("erase_customer", {
    p_shop_id: input.shop_id,
    p_customer_id: input.customer_id,
    p_actor: actor,
    p_dry_run: dryRun,
  });
  if (error) throw eraseRpcError(error);
  if (!data || typeof data !== "object") throw new Error("erase_customer returned nothing");
  return data as Record<string, unknown>;
}

function toPreview(data: Record<string, unknown>): ErasePreview {
  const count = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) ? v : 0);
  return {
    dry_run: true,
    mode: data.mode === "deleted" ? "deleted" : "anonymised",
    erased: data.erased === true,
    membership_active: data.membership_active === true,
    payments_in_progress: count(data.payments_in_progress),
    open_checkouts: count(data.open_checkouts),
    saved_cards: count(data.saved_cards),
  };
}

interface ScopeRow {
  id: string;
  stripe_customer_id: string | null;
}

/** The customer and every duplicate merged into them, recursively (the RPC's scope). */
async function eraseScope(s: Services, shopId: string, customerId: string): Promise<ScopeRow[]> {
  const rows: ScopeRow[] = [];
  const seen = new Set<string>();
  let frontier = [customerId];
  while (frontier.length > 0) {
    const first = rows.length === 0;
    const query = s.admin
      .from("customers")
      .select("id, stripe_customer_id")
      .eq("shop_id", shopId);
    const { data, error } = first
      ? await query.eq("id", customerId)
      : await query.in("merged_into_id", frontier);
    if (error) throw dbFailure("customers lookup", error);
    const found = ((data ?? []) as ScopeRow[]).filter((row) => !seen.has(row.id));
    if (first && found.length === 0) throw errors.notFound("Customer not found.");
    for (const row of found) {
      seen.add(row.id);
      rows.push(row);
    }
    frontier = found.map((row) => row.id);
  }
  return rows;
}

/** Ids of `table` rows of these customers (jobs / invoices), for their page holds. */
async function documentIds(
  s: Services,
  table: "jobs" | "invoices",
  shopId: string,
  customerIds: string[],
): Promise<string[]> {
  const { data, error } = await s.admin
    .from(table)
    .select("id")
    .eq("shop_id", shopId)
    .in("customer_id", customerIds);
  if (error) throw dbFailure(`${table} lookup`, error);
  return ((data ?? []) as Array<{ id: string }>).map((row) => row.id);
}

/** Detaches and removes every saved card of these customers. */
async function removeCards(
  s: Services,
  account: AccountRow,
  shopId: string,
  scope: ScopeRow[],
): Promise<{ removed: number; stripeCustomers: string[] }> {
  const { data, error } = await s.admin
    .from("customer_payment_methods")
    .select("customer_id, stripe_payment_method_id, stripe_customer_id")
    .eq("shop_id", shopId)
    .in("customer_id", scope.map((row) => row.id));
  if (error) throw dbFailure("customer_payment_methods lookup", error);
  const cards = (data ?? []) as Array<{
    customer_id: string;
    stripe_payment_method_id: string;
    stripe_customer_id: string | null;
  }>;
  const owners: string[] = [];
  let removed = 0;
  for (const card of cards) {
    // The Stripe customer the card is attached to: a card moved by a merge
    // (P-20) stays on the duplicate's Stripe customer.
    const owner = card.stripe_customer_id ??
      scope.find((row) => row.id === card.customer_id)?.stripe_customer_id ?? null;
    await detachCard(s, account, owner, card.stripe_payment_method_id);
    if (await removeCardRow(s, shopId, card.stripe_payment_method_id)) removed += 1;
    if (owner) owners.push(owner);
  }
  return { removed, stripeCustomers: owners };
}

/**
 * Deletes the Stripe Customers on the connected account (their payment
 * methods and any leftover subscription go with them). One that another CRM
 * customer of the shop still points at, or that Stripe no longer has, is
 * skipped.
 */
async function deleteStripeCustomers(
  s: Services,
  account: AccountRow,
  shopId: string,
  scope: ScopeRow[],
  stripeCustomers: string[],
): Promise<number> {
  const inScope = new Set(scope.map((row) => row.id));
  let deleted = 0;
  for (const stripeCustomer of new Set(stripeCustomers)) {
    const { data, error } = await s.admin
      .from("customers")
      .select("id")
      .eq("shop_id", shopId)
      .eq("stripe_customer_id", stripeCustomer);
    if (error) throw dbFailure("customers lookup", error);
    if (((data ?? []) as Array<{ id: string }>).some((row) => !inScope.has(row.id))) {
      s.log.warn("stripe_customer_shared", { shop_id: shopId, stripe_customer: stripeCustomer });
      continue;
    }
    try {
      await s.stripe.customers.del(
        stripeCustomer,
        {},
        onAccount(account.stripe_account_id, {
          idempotencyKey: await idempotencyKey("customer_delete", shopId, stripeCustomer),
        }),
      );
      deleted += 1;
    } catch (err) {
      // Already deleted, or not on this account (the shop connected another one).
      if (!isInvalidRequest(err)) throw err;
      s.log.warn("stripe_customer_delete_skipped", {
        shop_id: shopId,
        stripe_customer: stripeCustomer,
      });
    }
  }
  return deleted;
}

export async function eraseCustomer(
  s: Services,
  req: Request,
  input: z.output<typeof eraseCustomerInput>,
): Promise<ErasePreview | EraseResult> {
  const caller = await requireUser(req, { admin: s.admin });
  await requireShopRole(s.admin, caller, input.shop_id, ROLES.adminPlus);
  const preview = toPreview(await eraseRpc(s, input, caller.id, true));
  if (input.confirm !== true) return preview;
  // Still billing the card: nothing is touched until it is cancelled.
  if (preview.membership_active) throw refusal("membership_active");

  const scope = await eraseScope(s, input.shop_id, input.customer_id);
  const customerIds = scope.map((row) => row.id);
  let paymentsCancelled = 0;
  let sessionsExpired = 0;
  let cardsRemoved = 0;
  let stripeCustomersDeleted = 0;
  const account = await findAccount(s.admin, input.shop_id);
  if (account) {
    const settled = await settleCustomers(s, account, input.shop_id, customerIds);
    if (settled.in_progress > 0) throw paymentInProgress();
    paymentsCancelled = settled.cancelled;
    // An ACH debit / pay-later payment still clearing settles days later.
    const clearing = await s.admin
      .from("payments")
      .select("id")
      .eq("shop_id", input.shop_id)
      .in("customer_id", customerIds)
      .eq("status", "processing")
      .limit(1);
    if (clearing.error) throw dbFailure("processing payments lookup", clearing.error);
    if ((clearing.data ?? []).length > 0) throw paymentInProgress();

    const stripeCustomers = scope
      .map((row) => row.stripe_customer_id)
      .filter((id): id is string => id !== null);
    sessionsExpired = await releaseCustomerPages(s, account, {
      shopId: input.shop_id,
      stripeCustomers,
      jobIds: await documentIds(s, "jobs", input.shop_id, customerIds),
      invoiceIds: await documentIds(s, "invoices", input.shop_id, customerIds),
    });
    const cards = await removeCards(s, account, input.shop_id, scope);
    cardsRemoved = cards.removed;
    stripeCustomersDeleted = await deleteStripeCustomers(s, account, input.shop_id, scope, [
      ...stripeCustomers,
      ...cards.stripeCustomers,
    ]);
  }

  const result = await eraseRpc(s, input, caller.id, false);
  const mode = result.mode === "deleted" ? "deleted" : "anonymised";
  // No personal data in the log: ids and counts only.
  s.log.info("customer_erased", {
    shop_id: input.shop_id,
    customer_id: input.customer_id,
    mode,
    erased_by: caller.id,
    payments_cancelled: paymentsCancelled,
    sessions_expired: sessionsExpired,
    cards_removed: cardsRemoved,
    stripe_customers_deleted: stripeCustomersDeleted,
  });
  return {
    erased: true,
    mode,
    payments_cancelled: paymentsCancelled,
    sessions_expired: sessionsExpired,
    cards_removed: cardsRemoved,
    stripe_customers_deleted: stripeCustomersDeleted,
  };
}
