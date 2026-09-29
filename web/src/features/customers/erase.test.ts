import { describe, expect, it } from 'vitest';
import { EdgeFunctionError } from '@/features/quotes/shared/edge';
import { AppError } from '@/lib/errors';
import {
  eraseBlocked,
  eraseErrorMessage,
  eraseNotes,
  erasePreviewSchema,
  eraseResultSchema,
  eraseToast,
  type ErasePreview,
} from './erase';

const base: ErasePreview = {
  dry_run: true,
  mode: 'deleted',
  erased: false,
  membership_active: false,
  payments_in_progress: 0,
  open_checkouts: 0,
  saved_cards: 0,
};

const refusal = (reason: string) =>
  new EdgeFunctionError('server wording', {
    kind: 'conflict',
    status: 409,
    edgeCode: 'conflict',
    reason,
    details: { reason },
  });

describe('erase_customer preview', () => {
  it('parses the dry run and the result, and rejects anything else', () => {
    expect(erasePreviewSchema.parse(base)).toEqual(base);
    expect(erasePreviewSchema.safeParse({ ...base, mode: 'archived' }).success).toBe(false);
    expect(erasePreviewSchema.safeParse({ ...base, dry_run: false }).success).toBe(false);
    expect(
      eraseResultSchema.parse({
        erased: true,
        mode: 'anonymised',
        payments_cancelled: 1,
        sessions_expired: 2,
        cards_removed: 1,
        stripe_customers_deleted: 1,
      }).mode,
    ).toBe('anonymised');
    // the preview is not a result (a confirm must never be mistaken for a dry run)
    expect(eraseResultSchema.safeParse(base).success).toBe(false);
  });

  it('has nothing to say about a customer with nothing open', () => {
    expect(eraseNotes(base)).toEqual([]);
    expect(eraseBlocked(base)).toBe(false);
  });

  it('only an active membership blocks: the rest the server clears itself', () => {
    const preview = {
      ...base,
      mode: 'anonymised' as const,
      membership_active: true,
      payments_in_progress: 2,
      open_checkouts: 3,
      saved_cards: 1,
    };
    expect(eraseBlocked(preview)).toBe(true);
    expect(eraseBlocked({ ...preview, membership_active: false })).toBe(false);
    const notes = eraseNotes(preview);
    expect(notes.map((n) => n.tone)).toEqual(['blocker', 'info', 'info', 'info']);
    expect(notes[0]?.text).toMatch(/Cancel it on the Memberships tab first/);
    expect(notes[1]?.text).toMatch(/^2 payments from this customer are still in progress/);
    expect(notes[1]?.text).toMatch(/never completed are cancelled first/);
    expect(notes[2]?.text).toBe(
      '3 payment pages (pay or deposit links) are still open. They are closed first, so the links stop working.',
    );
    expect(notes[3]?.text).toBe('1 saved card is removed from your Stripe account.');
  });

  it('uses the singular for one of each', () => {
    const notes = eraseNotes({
      ...base,
      payments_in_progress: 1,
      open_checkouts: 1,
      saved_cards: 2,
    });
    expect(notes.map((n) => n.text)).toEqual([
      expect.stringMatching(/^1 payment from this customer is still in progress/),
      '1 payment page (a pay or deposit link) is still open. It is closed first, so the link stops working.',
      '2 saved cards are removed from your Stripe account.',
    ]);
  });
});

describe('erase_customer errors', () => {
  it('maps every 409 reason to a sentence', () => {
    expect(eraseErrorMessage(refusal('membership_active'))).toMatch(
      /membership that is still active\. Cancel it on the Memberships tab first.*Nothing was changed\./,
    );
    expect(eraseErrorMessage(refusal('payment_in_progress'))).toMatch(
      /still going through .*Try again once it has finished\. The customer’s record wasn’t changed\./,
    );
    expect(eraseErrorMessage(refusal('checkout_open'))).toMatch(
      /payment page for this customer was opened while deleting\. Try again in a moment\./,
    );
    expect(eraseErrorMessage(refusal('saved_cards'))).toMatch(
      /card was saved for this customer while deleting\. Try again in a moment\./,
    );
  });

  it('explains permission and not-found answers, and passes anything else through', () => {
    expect(
      eraseErrorMessage(new EdgeFunctionError('Forbidden', { kind: 'permission', status: 403 })),
    ).toBe('Only the shop’s owner or an admin can delete customers.');
    expect(
      eraseErrorMessage(
        new EdgeFunctionError('Customer not found.', { kind: 'not_found', status: 404 }),
      ),
    ).toBe('This customer no longer exists. It may have been deleted already.');
    expect(eraseErrorMessage(refusal('something_new'))).toBe('server wording');
    expect(eraseErrorMessage(new AppError('Can’t reach the server.', { kind: 'network' }))).toBe(
      'Can’t reach the server.',
    );
  });
});

describe('erase_customer success toast', () => {
  const result = {
    erased: true as const,
    payments_cancelled: 0,
    sessions_expired: 0,
    cards_removed: 0,
    stripe_customers_deleted: 0,
  };

  it('names the mode the server applied', () => {
    expect(eraseToast('Jane Doe', { ...result, mode: 'deleted' })).toEqual({
      title: 'Jane Doe deleted',
    });
    expect(eraseToast('Jane Doe', { ...result, mode: 'anonymised' })).toEqual({
      title: 'Jane Doe anonymised',
      description:
        'Their invoices, payments and job history are kept without their personal details.',
    });
  });
});
