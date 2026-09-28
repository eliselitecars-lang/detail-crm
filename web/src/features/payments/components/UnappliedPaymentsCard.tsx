import { FileInput, Undo2 } from 'lucide-react';
import { useState } from 'react';
import { Button, ErrorState, SectionCard } from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { RefundDialog } from '@/features/invoices/components/RefundDialog';
import { useUnappliedPayments } from '../api';
import { canApplyToInvoice, paymentMethodLabel, refundableCents } from '../paymentFormat';
import { ApplyPaymentDialog } from './ApplyPaymentDialog';
import type { Row } from '@/lib/db';

type Payment = Row<'payments'>;

/**
 * Money the customer paid that pays nothing (no invoice, job or membership):
 * the server keeps it here with a note when its job or invoice was deleted,
 * its invoice was voided, or its document moved to another customer. Staff
 * apply it to an open invoice (manager+) or refund it (owner/admin). Shown
 * only when there is some.
 */
export function UnappliedPaymentsCard({ customerId }: { customerId: string }) {
  const { timezone, currency } = useShop();
  const canView = useCan('payments.view');
  const canApply = useCan('invoices.manage');
  const canRefund = useCan('payments.refund');
  const payments = useUnappliedPayments(customerId, canView);
  const [applying, setApplying] = useState<Payment | null>(null);
  const [refunding, setRefunding] = useState<Payment | null>(null);
  const money = (cents: number) => formatCents(cents, { currency });

  if (!canView || payments.isPending) return null;
  if (payments.isError) {
    return (
      <SectionCard title="Unapplied payments" className="lg:col-span-2">
        <ErrorState
          compact
          title="Couldn’t check for unapplied payments"
          error={payments.error}
          onRetry={() => void payments.refetch()}
        />
      </SectionCard>
    );
  }
  if (payments.data.length === 0) return null;

  return (
    <SectionCard
      title="Unapplied payments"
      description="Money this customer paid that isn’t paying anything yet. Apply it to one of their invoices or refund it."
      className="lg:col-span-2"
      flush
    >
      <ul className="divide-line divide-y" aria-label="Unapplied payments">
        {payments.data.map((p) => (
          <li key={p.id} className="flex flex-wrap items-start gap-3 px-4 py-3">
            <div className="min-w-0 flex-1">
              <p className="text-ink text-sm font-medium">
                {paymentMethodLabel(p)} ·{' '}
                <span className="tabular-nums">{money(p.amount_cents)}</span>
                {p.refunded_cents > 0 && (
                  <span className="text-danger-ink text-xs font-normal">
                    {' '}
                    (−{money(p.refunded_cents)} refunded)
                  </span>
                )}
              </p>
              <p className="text-muted mt-0.5 text-xs">
                <time dateTime={p.paid_at ?? p.created_at}>
                  {formatDateTime(p.paid_at ?? p.created_at, timezone)}
                </time>
              </p>
              {p.note && (
                <p className="text-muted mt-0.5 text-xs break-words whitespace-pre-line">
                  {p.note}
                </p>
              )}
            </div>
            <div className="flex shrink-0 flex-wrap items-center gap-1">
              {canApply && canApplyToInvoice(p) && (
                <Button
                  size="sm"
                  variant="secondary"
                  leadingIcon={<FileInput className="size-4" aria-hidden="true" />}
                  onClick={() => setApplying(p)}
                  aria-label={`Apply ${money(p.amount_cents)} to an invoice`}
                >
                  Apply
                </Button>
              )}
              {canRefund && refundableCents(p) > 0 && (
                <Button
                  size="sm"
                  variant="ghost"
                  leadingIcon={<Undo2 className="size-4" aria-hidden="true" />}
                  onClick={() => setRefunding(p)}
                  aria-label={`Refund ${paymentMethodLabel(p)} payment of ${money(p.amount_cents)}`}
                >
                  Refund
                </Button>
              )}
            </div>
          </li>
        ))}
      </ul>
      <ApplyPaymentDialog
        payment={applying}
        onClose={() => setApplying(null)}
        currency={currency}
      />
      <RefundDialog payment={refunding} onClose={() => setRefunding(null)} currency={currency} />
    </SectionCard>
  );
}
