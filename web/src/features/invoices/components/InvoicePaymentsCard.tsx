import { Undo2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  EmptyState,
  ErrorState,
  LoadingState,
  SectionCard,
  StatusBadge,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useCan } from '@/features/shop/useCan';
import {
  KIND_LABELS,
  paymentMethodLabel,
  refundableCents,
} from '@/features/payments/paymentFormat';
import { useInvoicePayments, type InvoicePayment } from '../api';
import { RefundDialog } from './RefundDialog';

export interface InvoicePaymentsCardProps {
  invoiceId: string;
  currency: string;
  timezone: string;
}

export function InvoicePaymentsCard({ invoiceId, currency, timezone }: InvoicePaymentsCardProps) {
  const payments = useInvoicePayments(invoiceId);
  const canRefund = useCan('payments.refund');
  const [refunding, setRefunding] = useState<InvoicePayment | null>(null);
  const money = (cents: number) => formatCents(cents, { currency });

  return (
    <SectionCard title="Payments" flush>
      {payments.isPending ? (
        <LoadingState variant="rows" rows={2} label="Loading payments…" />
      ) : payments.isError ? (
        <ErrorState compact error={payments.error} onRetry={() => void payments.refetch()} />
      ) : payments.data.length === 0 ? (
        <EmptyState compact title="No payments yet" />
      ) : (
        <ul className="divide-line divide-y" aria-label="Payments">
          {payments.data.map((payment) => {
            const refundable = refundableCents(payment);
            return (
              <li key={payment.id} className="flex flex-wrap items-start gap-3 px-4 py-3">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-ink text-sm font-medium">
                      {paymentMethodLabel(payment)}
                    </span>
                    {payment.kind !== 'payment' && (
                      <Badge tone="neutral">{KIND_LABELS[payment.kind]}</Badge>
                    )}
                    <StatusBadge kind="payment" status={payment.status} />
                  </div>
                  <p className="text-muted mt-0.5 text-xs">
                    <time dateTime={payment.paid_at ?? payment.created_at}>
                      {formatDateTime(payment.paid_at ?? payment.created_at, timezone)}
                    </time>
                  </p>
                  {payment.note && (
                    <p className="text-muted mt-0.5 text-xs break-words">{payment.note}</p>
                  )}
                </div>
                <div className="flex shrink-0 flex-col items-end gap-0.5 text-right">
                  <span className="text-ink text-sm font-medium tabular-nums">
                    {money(payment.amount_cents)}
                  </span>
                  {payment.tip_cents > 0 && (
                    <span className="text-muted text-xs tabular-nums">
                      + {money(payment.tip_cents)} tip
                    </span>
                  )}
                  {payment.refunded_cents > 0 && (
                    <span className="text-danger-ink text-xs tabular-nums">
                      −{money(payment.refunded_cents)} refunded
                    </span>
                  )}
                  {canRefund && refundable > 0 && (
                    <Button
                      size="sm"
                      variant="ghost"
                      className="mt-1"
                      leadingIcon={<Undo2 className="size-4" aria-hidden="true" />}
                      onClick={() => setRefunding(payment)}
                      aria-label={`Refund ${paymentMethodLabel(payment)} payment of ${money(payment.amount_cents)}`}
                    >
                      Refund
                    </Button>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
      <RefundDialog payment={refunding} onClose={() => setRefunding(null)} currency={currency} />
    </SectionCard>
  );
}
