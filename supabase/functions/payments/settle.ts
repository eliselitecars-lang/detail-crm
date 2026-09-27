/**
 * Settling unconfirmed card attempts. payment_sheet records a `pending`
 * payment row as soon as it creates the PaymentIntent (the SQL money guards
 * treat a pending row as "payment in progress" and refuse void / pricing /
 * line-item changes). Stripe never cancels an unconfirmed PaymentIntent on
 * its own, so an abandoned sheet would lock the invoice forever. Every
 * pending row is therefore brought in line with Stripe:
 *
 *   succeeded                         -> recorded as succeeded
 *   canceled                          -> recorded as cancelled
 *   requires_payment_method/_confirmation/_action on a payment_sheet intent
 *                                     -> cancelled in Stripe, recorded cancelled
 *   processing / requires_capture / anything not ours -> left pending ("in progress")
 *
 * A DECLINED sheet is recorded `failed` by the webhook, but its intent goes
 * back to requires_payment_method and the open sheet can still confirm it
 * with another card. Recent failed rows (FAILED_SHEET_WINDOW_MS) are settled
 * the same way, so a declined sheet is superseded, released and swept like a
 * pending one; a failed row whose intent cannot be paid any more is left as
 * it is ("unchanged", never "in progress").
 *
 * Used by payment_sheet and charge_saved_card (a new attempt supersedes older
 * ones), the public invoice / deposit checkouts (a pay link supersedes an
 * open sheet; money already processing blocks it), the cancel_open_payments
 * action (sheet dismissed, before void / edits, before a job is cancelled or
 * changes customer), delete_shop (every open attempt of the shop) and the
 * sweep_payment_sheets cron action (sheets abandoned without either).
 */
import { onAccount, type Stripe } from "../_shared/stripe.ts";
import {
  type AccountRow,
  dbFailure,
  findAccount,
  isInvalidRequest,
  rpcError,
  type Services,
} from "./lib.ts";

/** payment_sheet intents unconfirmed this long are abandoned (cron sweep). */
export const STALE_SHEET_MS = 30 * 60 * 1000;
/** Rows settled per sweep run (each costs one or two Stripe calls). */
export const SWEEP_BATCH = 25;
/** Stale rows the sweep considers per run (newest first). */
export const SWEEP_SCAN_LIMIT = 1000;
/** The sweep's rotation period (the pg_cron schedule in supabase/setup/cron.sql). */
export const SWEEP_SLOT_MS = 10 * 60 * 1000;
/** Declined (failed) sheets stay confirmable on the device; settle them this long. */
export const FAILED_SHEET_WINDOW_MS = 24 * 60 * 60 * 1000;

/**
 * succeeded / cancelled: recorded. in_progress: money may still move (blocks
 * a new attempt). kept: the caller's own retry. unchanged: a failed row that
 * can no longer be paid (never blocks).
 */
export type Settlement = "succeeded" | "cancelled" | "in_progress" | "kept" | "unchanged";

export interface PendingCardRow {
  id: string;
  shop_id: string;
  invoice_id: string | null;
  job_id: string | null;
  customer_id: string;
  kind: "deposit" | "payment" | "membership";
  method: "card" | "card_present";
  status: "pending" | "failed";
  amount_cents: number;
  tip_cents: number;
  stripe_payment_intent_id: string;
  created_at: string;
}

const PENDING_COLUMNS =
  "id, shop_id, invoice_id, job_id, customer_id, kind, method, status, amount_cents, tip_cents, stripe_payment_intent_id, created_at";

const UNCONFIRMED = new Set([
  "requires_payment_method",
  "requires_confirmation",
  "requires_action",
]);

/**
 * Unsettled card rows of an invoice or a job: pending ones, plus failed ones
 * from the last FAILED_SHEET_WINDOW_MS (membership rows belong to Stripe
 * Billing).
 */
async function openRows(
  s: Services,
  shopId: string,
  scope: { column: "invoice_id" | "job_id"; id: string } | null,
): Promise<PendingCardRow[]> {
  let query = s.admin
    .from("payments")
    .select(PENDING_COLUMNS)
    .eq("shop_id", shopId);
  if (scope) query = query.eq(scope.column, scope.id);
  const { data, error } = await query
    .in("status", ["pending", "failed"])
    .in("method", ["card", "card_present"])
    .neq("kind", "membership")
    .order("created_at", { ascending: true });
  if (error) throw dbFailure("pending payments lookup", error);
  const failedSince = s.now - FAILED_SHEET_WINDOW_MS;
  return ((data ?? []) as PendingCardRow[]).filter((row) =>
    row.stripe_payment_intent_id &&
    (row.status === "pending" || Date.parse(row.created_at) >= failedSince)
  );
}

/** Unsettled card rows of an invoice. */
export function pendingInvoiceRows(
  s: Services,
  shopId: string,
  invoiceId: string,
): Promise<PendingCardRow[]> {
  return openRows(s, shopId, { column: "invoice_id", id: invoiceId });
}

/** Unsettled card rows of a job (its deposits and its invoices' payments). */
export function pendingJobRows(
  s: Services,
  shopId: string,
  jobId: string,
): Promise<PendingCardRow[]> {
  return openRows(s, shopId, { column: "job_id", id: jobId });
}

/** Every unsettled card row of a shop (shop deletion). */
export function pendingShopRows(s: Services, shopId: string): Promise<PendingCardRow[]> {
  return openRows(s, shopId, null);
}

/**
 * Sweep candidates, any shop (cron only): pending card rows older than
 * STALE_SHEET_MS and failed ones from the FAILED_SHEET_WINDOW_MS window.
 */
export async function stalePendingRows(s: Services): Promise<PendingCardRow[]> {
  const staleBefore = new Date(s.now - STALE_SHEET_MS).toISOString();
  const base = () =>
    s.admin
      .from("payments")
      .select(PENDING_COLUMNS)
      .in("method", ["card", "card_present"])
      .neq("kind", "membership")
      .lt("created_at", staleBefore);
  const pending = await base()
    .eq("status", "pending")
    .order("created_at", { ascending: false })
    .limit(SWEEP_SCAN_LIMIT);
  if (pending.error) throw dbFailure("stale payments lookup", pending.error);
  const failed = await base()
    .eq("status", "failed")
    .gte("created_at", new Date(s.now - FAILED_SHEET_WINDOW_MS).toISOString())
    .order("created_at", { ascending: false })
    .limit(SWEEP_SCAN_LIMIT);
  if (failed.error) throw dbFailure("failed payments lookup", failed.error);
  return [...(pending.data ?? []), ...(failed.data ?? [])]
    .filter((row) => (row as PendingCardRow).stripe_payment_intent_id) as PendingCardRow[];
}

/** Newly stale rows (never swept yet) take up to this share of a batch. */
const NEW_STALE_SHARE = Math.ceil(SWEEP_BATCH / 2);

function byId(a: PendingCardRow, b: PendingCardRow): number {
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/**
 * The rows one sweep run settles. Rows the sweep cannot close (payments
 * processing for days, other flows' intents, shops without an account,
 * Stripe errors) stay candidates, so a fixed "oldest first" batch would
 * re-check the same rows forever and never reach newer abandoned sheets.
 * Over SWEEP_BATCH candidates:
 *   - rows that went stale in the last two runs (never swept yet: most
 *     abandoned sheets) come first, newest first, up to NEW_STALE_SHARE;
 *   - the rest of the batch walks round-robin over the other candidates
 *     (ordered by id, the window advancing each SWEEP_SLOT_MS), so every
 *     candidate is re-checked within ceil(candidates / slots) runs whatever
 *     the other tenants' rows do.
 */
export function sweepBatch(rows: PendingCardRow[], now: number): PendingCardRow[] {
  if (rows.length <= SWEEP_BATCH) return rows;
  const newSince = now - STALE_SHEET_MS - 2 * SWEEP_SLOT_MS;
  const fresh = rows
    .filter((row) => Date.parse(row.created_at) >= newSince)
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at) || byId(a, b))
    .slice(0, NEW_STALE_SHARE);
  const taken = new Set(fresh.map((row) => row.id));
  const rest = rows.filter((row) => !taken.has(row.id)).sort(byId);
  const room = Math.min(SWEEP_BATCH - fresh.length, rest.length);
  const start = rest.length ? (Math.floor(now / SWEEP_SLOT_MS) * room) % rest.length : 0;
  const rotated: PendingCardRow[] = [];
  for (let i = 0; i < room; i++) {
    const row = rest[(start + i) % rest.length];
    if (row) rotated.push(row);
  }
  return [...fresh, ...rotated];
}

async function record(
  s: Services,
  row: PendingCardRow,
  status: "succeeded" | "cancelled",
  intent?: Stripe.PaymentIntent,
): Promise<void> {
  const charge = intent?.latest_charge;
  const chargeId = typeof charge === "string" ? charge : charge?.id ?? null;
  const created = typeof charge === "object" && charge !== null ? charge.created : null;
  const { error } = await s.admin.rpc("upsert_stripe_payment", {
    p_shop_id: row.shop_id,
    p_payment_intent_id: row.stripe_payment_intent_id,
    p_status: status,
    p_amount_cents: row.amount_cents,
    p_tip_cents: row.tip_cents,
    p_kind: row.kind,
    p_method: row.method,
    p_invoice_id: row.invoice_id,
    p_job_id: row.job_id,
    p_customer_id: row.customer_id,
    ...(status === "succeeded"
      ? {
        p_charge_id: chargeId && /^(ch|py)_[A-Za-z0-9]+$/.test(chargeId) ? chargeId : null,
        p_paid_at: new Date(created ? created * 1000 : s.now).toISOString(),
      }
      : {}),
  });
  if (error) throw rpcError("upsert_stripe_payment", error);
}

function isMissing(err: unknown): boolean {
  return isInvalidRequest(err) &&
    ((err as { code?: unknown }).code === "resource_missing" ||
      (err as { statusCode?: unknown }).statusCode === 404);
}

async function retrieve(
  s: Services,
  account: AccountRow,
  id: string,
): Promise<Stripe.PaymentIntent | null> {
  try {
    return await s.stripe.paymentIntents.retrieve(
      id,
      { expand: ["latest_charge"] },
      onAccount(account.stripe_account_id),
    );
  } catch (err) {
    if (isMissing(err)) return null;
    throw err;
  }
}

/**
 * Brings one pending (or recently failed) row in line with its
 * PaymentIntent. `keepRequestKey` leaves alone the intent a retry of the same
 * payment_sheet request created (it is handed back to that request, not
 * cancelled under it).
 */
export async function settlePending(
  s: Services,
  account: AccountRow,
  row: PendingCardRow,
  options: { keepRequestKey?: string } = {},
): Promise<Settlement> {
  // A failed row only matters while its intent can still take money.
  const idle: Settlement = row.status === "failed" ? "unchanged" : "in_progress";
  let intent = await retrieve(s, account, row.stripe_payment_intent_id);
  if (!intent) {
    if (row.status === "failed") return "unchanged";
    // Not on the shop's (current) account: it can never be paid there.
    s.log.warn("pending_payment_intent_missing", { shop_id: row.shop_id, payment_id: row.id });
    await record(s, row, "cancelled");
    return "cancelled";
  }
  if (intent.metadata?.shop_id && intent.metadata.shop_id !== row.shop_id) return idle;
  // A declined attempt whose intent was closed since keeps its 'failed' record.
  if (row.status === "failed" && intent.status === "canceled") return "unchanged";
  if (
    options.keepRequestKey && intent.metadata?.request_key === options.keepRequestKey &&
    UNCONFIRMED.has(intent.status)
  ) {
    return "kept";
  }

  if (UNCONFIRMED.has(intent.status)) {
    // Only abandon what payment_sheet created; other flows own their intents
    // (a declined off-session charge_saved_card intent is never re-confirmed).
    if (intent.metadata?.source !== "payment_sheet") return idle;
    try {
      // No fixed idempotency key: Stripe would replay a cached refusal (the
      // intent was processing) after the intent returned to an unconfirmed
      // state. Cancelling twice is harmless (the second is refused, below).
      intent = await s.stripe.paymentIntents.cancel(
        intent.id,
        { cancellation_reason: "abandoned" },
        onAccount(account.stripe_account_id),
      );
    } catch (err) {
      // The customer confirmed at the same moment: use Stripe's current state.
      if (!isInvalidRequest(err)) throw err;
      intent = await retrieve(s, account, row.stripe_payment_intent_id);
      if (!intent) return idle;
    }
  }

  const state = settledState(intent.status);
  if (state === "succeeded") await record(s, row, "succeeded", intent);
  if (state === "cancelled") await record(s, row, "cancelled");
  return state;
}

function settledState(status: Stripe.PaymentIntent.Status): Settlement {
  if (status === "succeeded") return "succeeded";
  if (status === "canceled") return "cancelled";
  // processing / requires_capture (or an unconfirmed intent the cancel lost
  // to a confirmation): money may still move.
  return "in_progress";
}

export interface SettleSummary {
  succeeded: number;
  cancelled: number;
  in_progress: number;
  kept: PendingCardRow[];
}

async function settleRows(
  s: Services,
  account: AccountRow,
  rows: PendingCardRow[],
  options: { keepRequestKey?: string },
): Promise<SettleSummary> {
  const summary: SettleSummary = { succeeded: 0, cancelled: 0, in_progress: 0, kept: [] };
  for (const row of rows) {
    const state = await settlePending(s, account, row, options);
    if (state === "kept") summary.kept.push(row);
    else if (state !== "unchanged") summary[state] += 1;
  }
  return summary;
}

/** Settles every unsettled card row of an invoice. */
export async function settleInvoice(
  s: Services,
  account: AccountRow,
  shopId: string,
  invoiceId: string,
  options: { keepRequestKey?: string } = {},
): Promise<SettleSummary> {
  return await settleRows(s, account, await pendingInvoiceRows(s, shopId, invoiceId), options);
}

/** Settles every unsettled card row of a job (deposits and its invoices' payments). */
export async function settleJob(
  s: Services,
  account: AccountRow,
  shopId: string,
  jobId: string,
): Promise<SettleSummary> {
  return await settleRows(s, account, await pendingJobRows(s, shopId, jobId), {});
}

/** Settles every unsettled card row of a shop (before the shop is deleted). */
export async function settleShop(
  s: Services,
  account: AccountRow,
  shopId: string,
): Promise<SettleSummary> {
  return await settleRows(s, account, await pendingShopRows(s, shopId), {});
}

/** Cron: settle abandoned payment_sheet rows across shops, one failure never stops the batch. */
export async function sweepStale(s: Services): Promise<Record<string, number>> {
  const rows = sweepBatch(await stalePendingRows(s), s.now);
  const accounts = new Map<string, AccountRow | null>();
  const counts = {
    checked: rows.length,
    succeeded: 0,
    cancelled: 0,
    in_progress: 0,
    unchanged: 0,
    failed: 0,
  };
  for (const row of rows) {
    try {
      if (!accounts.has(row.shop_id)) {
        accounts.set(row.shop_id, await findAccount(s.admin, row.shop_id));
      }
      const account = accounts.get(row.shop_id);
      if (!account) {
        counts[row.status === "failed" ? "unchanged" : "in_progress"] += 1;
        continue;
      }
      const state = await settlePending(s, account, row);
      counts[state === "kept" ? "in_progress" : state] += 1;
    } catch (err) {
      counts.failed += 1;
      s.log.error("payment_sweep_failed", {
        shop_id: row.shop_id,
        payment_id: row.id,
        error: err instanceof Error ? err.message : "unknown",
      });
    }
  }
  return counts;
}
