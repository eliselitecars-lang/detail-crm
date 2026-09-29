/**
 * A customer's deletion request: payments → erase_customer (owner / admin;
 * supabase/functions/README.md → erase_customer, migration 0125). The
 * server decides what happens to the record: it is deleted when no job,
 * invoice, payment or membership references it, otherwise it is anonymised
 * in place (invoices, payments and job history keep their amounts, numbers
 * and dates without the personal details), together with every duplicate
 * merged into it. The page first asks for the dry run (no `confirm`: nothing
 * changes, Stripe is not called), shows what will happen and what is in the
 * way, and only then confirms.
 *
 * What the confirm step resolves by itself: unfinished card payment
 * attempts are cancelled, open pay / deposit pages are closed and saved
 * cards are detached in Stripe and removed. What it refuses (409): an
 * active, past-due or incomplete membership (it still bills the card — the
 * shop cancels it first), money still moving (a bank debit clearing, a page
 * that was just paid) and a page or card that appeared meanwhile.
 */
import { z } from 'zod';
import { EdgeFunctionError } from '@/features/quotes/shared/edge';
import { errorMessage, toAppError } from '@/lib/errors';

export const ERASE_MODES = ['deleted', 'anonymised'] as const;
export type EraseMode = (typeof ERASE_MODES)[number];

const count = z.number().int().nonnegative();

/** erase_customer without `confirm`: the RPC's dry run. */
export const erasePreviewSchema = z.object({
  dry_run: z.literal(true),
  mode: z.enum(ERASE_MODES),
  /** Already erased (anonymised) at an earlier request. */
  erased: z.boolean(),
  /** An active, past-due or incomplete membership: refused until it is cancelled. */
  membership_active: z.boolean(),
  payments_in_progress: count,
  open_checkouts: count,
  saved_cards: count,
});
export type ErasePreview = z.infer<typeof erasePreviewSchema>;

/** erase_customer with `confirm: true`. */
export const eraseResultSchema = z.object({
  erased: z.literal(true),
  mode: z.enum(ERASE_MODES),
  payments_cancelled: count,
  sessions_expired: count,
  cards_removed: count,
  stripe_customers_deleted: count,
});
export type EraseResult = z.infer<typeof eraseResultSchema>;

export interface EraseNote {
  /** `blocker`: the server refuses until the shop acts; `info`: done as part of it. */
  tone: 'blocker' | 'info';
  text: string;
}

/** The server refuses to erase until the shop acts first. */
export function eraseBlocked(preview: ErasePreview): boolean {
  return preview.membership_active;
}

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many);

/** What stands in the way, and what the confirm step also does, from the dry run. */
export function eraseNotes(preview: ErasePreview): EraseNote[] {
  const notes: EraseNote[] = [];
  if (preview.membership_active) {
    notes.push({
      tone: 'blocker',
      text: 'This customer has a membership that is still active, past due or waiting for its first payment, so it can still bill their card. Cancel it on the Memberships tab first, then come back to delete the customer.',
    });
  }
  if (preview.payments_in_progress > 0) {
    const n = preview.payments_in_progress;
    notes.push({
      tone: 'info',
      text: `${plural(n, '1 payment from this customer is', `${n} payments from this customer are`)} still in progress. Card payments that were never completed are cancelled first; if money is still moving (for example a bank debit that is clearing), the customer can’t be deleted until it has finished.`,
    });
  }
  if (preview.open_checkouts > 0) {
    const n = preview.open_checkouts;
    notes.push({
      tone: 'info',
      text: `${plural(n, '1 payment page (a pay or deposit link) is', `${n} payment pages (pay or deposit links) are`)} still open. ${plural(n, 'It is', 'They are')} closed first, so the ${plural(n, 'link stops', 'links stop')} working.`,
    });
  }
  if (preview.saved_cards > 0) {
    const n = preview.saved_cards;
    notes.push({
      tone: 'info',
      text: `${plural(n, '1 saved card is', `${n} saved cards are`)} removed from your Stripe account.`,
    });
  }
  return notes;
}

/** The erase_customer 409 reasons, worded for the owner / admin. */
const REFUSALS: Readonly<Record<string, string>> = {
  membership_active:
    'This customer has a membership that is still active. Cancel it on the Memberships tab first, then delete the customer. Nothing was changed.',
  payment_in_progress:
    'A payment from this customer is still going through (for example a bank debit that is clearing, or a payment page that was just paid). Try again once it has finished. The customer’s record wasn’t changed.',
  checkout_open:
    'A payment page for this customer was opened while deleting. Try again in a moment. The customer’s record wasn’t changed.',
  saved_cards:
    'A card was saved for this customer while deleting. Try again in a moment. The customer’s record wasn’t changed.',
};

/** Friendly text for an erase_customer failure (preview or confirm). */
export function eraseErrorMessage(error: unknown): string {
  if (error instanceof EdgeFunctionError && error.reason && error.reason in REFUSALS) {
    return REFUSALS[error.reason] ?? errorMessage(error);
  }
  const kind = toAppError(error).kind;
  if (kind === 'permission') return 'Only the shop’s owner or an admin can delete customers.';
  if (kind === 'not_found')
    return 'This customer no longer exists. It may have been deleted already.';
  return errorMessage(error);
}

/** The success toast for the mode the server applied. */
export function eraseToast(
  name: string,
  result: EraseResult,
): { title: string; description?: string } {
  if (result.mode === 'deleted') return { title: `${name} deleted` };
  return {
    title: `${name} anonymised`,
    description:
      'Their invoices, payments and job history are kept without their personal details.',
  };
}
