import { useState } from 'react';
import { Button, Dialog, FormField, MoneyInput, useToast } from '@/components/ui';
import { formatCents } from '@/lib/money';
import { EdgeFunctionError } from '@/features/quotes/shared/edge';
import { newRequestNonce } from '@/features/quotes/shared/format';
import {
  isStripeMethod,
  paymentMethodLabel,
  refundableCents,
} from '@/features/payments/paymentFormat';
import { useRefundPayment, type InvoicePayment } from '../api';

export interface RefundDialogProps {
  payment: InvoicePayment | null;
  onClose: () => void;
  currency: string;
}

/** Owner/admin refund of one payment (card via Stripe, manual via the RPC). */
export function RefundDialog({ payment, onClose, currency }: RefundDialogProps) {
  return (
    <Dialog
      open={payment !== null}
      onClose={onClose}
      title="Refund payment"
      description={
        payment
          ? isStripeMethod(payment.method)
            ? `Refunds ${paymentMethodLabel(payment)} through Stripe. It can take 5–10 days to reach the customer.`
            : payment.method === 'gift_card'
              ? 'Puts the amount back on the gift card or store credit it was paid with.'
              : `Records money handed back for this ${paymentMethodLabel(payment).toLowerCase()} payment.`
          : undefined
      }
      size="sm"
    >
      {payment && <RefundForm payment={payment} onClose={onClose} currency={currency} />}
    </Dialog>
  );
}

function RefundForm({
  payment,
  onClose,
  currency,
}: {
  payment: InvoicePayment;
  onClose: () => void;
  currency: string;
}) {
  const toast = useToast();
  const refund = useRefundPayment();
  const max = refundableCents(payment);
  const [amount, setAmount] = useState<number | null>(max);
  // One nonce per refund attempt: kept across network/5xx retries (so a lost
  // response never refunds twice), replaced after a definitive answer.
  const [nonce, setNonce] = useState(newRequestNonce);
  const error =
    amount === null || amount <= 0
      ? 'Enter an amount greater than zero.'
      : amount > max
        ? `You can refund up to ${formatCents(max, { currency })}.`
        : undefined;

  const submit = async () => {
    if (error || amount === null) return;
    try {
      await refund.mutateAsync({ payment, amountCents: amount, nonce });
      toast.success(`${formatCents(amount, { currency })} refunded`);
      onClose();
    } catch (err) {
      if (err instanceof EdgeFunctionError && err.status !== undefined && err.status < 500) {
        // A definitive answer (not refundable, amount too high…): a new try is a new attempt.
        setNonce(newRequestNonce());
      }
      toast.error(err);
    }
  };

  return (
    <form
      noValidate
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <FormField
        label="Refund amount"
        required
        error={amount === null ? undefined : error}
        help={`Refundable: ${formatCents(max, { currency })}${payment.tip_cents > 0 ? ' (includes the tip)' : ''}`}
      >
        <MoneyInput value={amount} onChange={setAmount} />
      </FormField>
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={refund.isPending}>
          Cancel
        </Button>
        <Button type="submit" variant="danger" loading={refund.isPending} disabled={Boolean(error)}>
          {amount && !error ? `Refund ${formatCents(amount, { currency })}` : 'Refund'}
        </Button>
      </div>
    </form>
  );
}
