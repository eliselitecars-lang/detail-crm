import { Hourglass } from 'lucide-react';
import { useState } from 'react';
import { Button } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { cancelOpenPaymentsSummary, useCancelOpenPayments } from '../api';

export interface CheckoutOpenNoticeProps {
  invoiceId: string;
  /** The server's checkout_open refusal (its message says until when). */
  error: unknown;
  /** Runs the refused payment (or void) again once the open pages are released. */
  onRetry: () => Promise<void>;
}

/**
 * A manual payment / gift card / store credit, or voiding the invoice (0116),
 * was refused because a card payment page for the invoice is still open
 * (55000 checkout_open). Offers to cancel the open payments
 * (payments.cancel_open_payments: expires the Stripe pages, releases the
 * hold) and then runs the same action again.
 * A payment the bank is already processing is never cancelled: then nothing
 * is retried and the notice says so.
 */
export function CheckoutOpenNotice({ invoiceId, error, onRetry }: CheckoutOpenNoticeProps) {
  const cancelOpen = useCancelOpenPayments(invoiceId);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  const release = async () => {
    setBusy(true);
    setProblem(null);
    try {
      const result = await cancelOpen.mutateAsync();
      if (result.in_progress > 0 || result.succeeded > 0) {
        // Money moved or is moving: don't record (or void) on top of it.
        const summary = cancelOpenPaymentsSummary(result);
        setProblem([summary.title, summary.description].filter(Boolean).join('. '));
        return;
      }
      await onRetry();
    } catch (err) {
      setProblem(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      role="alert"
      className="bg-warning-soft text-warning-ink rounded-card flex flex-col gap-3 px-4 py-3 text-sm"
    >
      <div className="flex gap-3">
        <Hourglass className="mt-0.5 size-5 shrink-0" aria-hidden="true" />
        <div className="min-w-0 flex-1">
          <p className="font-medium">A card payment page for this invoice is still open</p>
          <p className="mt-0.5">{errorMessage(error)}</p>
          {problem && <p className="mt-1 font-medium">{problem}</p>}
        </div>
      </div>
      <Button
        size="sm"
        variant="secondary"
        className="self-start"
        loading={busy}
        onClick={() => void release()}
      >
        Cancel open payments and try again
      </Button>
    </div>
  );
}
