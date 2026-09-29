import { useState } from 'react';
import { Link } from 'react-router';
import {
  Button,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  LoadingState,
  Select,
  useToast,
} from '@/components/ui';
import { isCheckoutOpenError } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { useApplicableInvoices, useApplyPaymentToInvoice } from '@/features/invoices/api';
import { CheckoutOpenNotice } from '@/features/invoices/components/CheckoutOpenNotice';

/** What applying a payment needs (a ledger row or a customer's unapplied payment). */
export interface ApplicablePayment {
  id: string;
  customer_id: string;
  amount_cents: number;
  refunded_cents: number;
}

export interface ApplyPaymentDialogProps {
  payment: ApplicablePayment | null;
  onClose: () => void;
  currency: string;
}

/**
 * Manager+: put an unapplied payment on one of the same customer's open
 * invoices (apply_payment_to_invoice). The server moves the whole payment
 * row (tip and refunds stay with it) and refuses a target it would overpay,
 * or one with a card payment page still open (55000 checkout_open, 0121):
 * then the dialog offers to cancel the open payments and apply again.
 */
export function ApplyPaymentDialog({ payment, onClose, currency }: ApplyPaymentDialogProps) {
  return (
    <Dialog
      open={payment !== null}
      onClose={onClose}
      title="Apply to an invoice"
      description="Puts this money toward one of the customer’s open invoices, so they don’t pay it twice."
      size="sm"
    >
      {payment && <ApplyForm payment={payment} onClose={onClose} currency={currency} />}
    </Dialog>
  );
}

function ApplyForm({
  payment,
  onClose,
  currency,
}: {
  payment: ApplicablePayment;
  onClose: () => void;
  currency: string;
}) {
  const toast = useToast();
  const invoices = useApplicableInvoices(payment.customer_id, true);
  const apply = useApplyPaymentToInvoice();
  const [invoiceId, setInvoiceId] = useState('');
  /** The chosen invoice's checkout_open refusal (a card page is still open). */
  const [held, setHeld] = useState<{ invoiceId: string; error: unknown } | null>(null);
  const money = (cents: number) => formatCents(cents, { currency });
  // Tips never count toward an invoice (payment_net_amount).
  const net = Math.max(
    0,
    payment.amount_cents - Math.min(payment.refunded_cents, payment.amount_cents),
  );

  if (invoices.isPending) return <LoadingState variant="rows" rows={2} label="Loading invoices…" />;
  if (invoices.isError) {
    return (
      <ErrorState
        compact
        title="Couldn’t load this customer’s invoices"
        error={invoices.error}
        onRetry={() => void invoices.refetch()}
      />
    );
  }
  if (invoices.data.length === 0) {
    return (
      <div className="flex flex-col gap-4">
        <EmptyState
          compact
          title="No open invoices for this customer"
          description="Create or send an invoice for them first, or refund the payment."
        />
        <div className="flex justify-end">
          <Button variant="secondary" onClick={onClose}>
            Close
          </Button>
        </div>
      </div>
    );
  }

  const chosen = invoices.data.find((i) => i.id === invoiceId);
  const error =
    chosen && net > chosen.balance_cents
      ? `Invoice #${chosen.number} has ${money(chosen.balance_cents)} due, less than this payment. Choose another invoice or refund the payment.`
      : undefined;

  /** Applies to `target`; throws the server's refusal. */
  const applyTo = async (target: { id: string; number: number }) => {
    await apply.mutateAsync({ paymentId: payment.id, invoiceId: target.id });
    setHeld(null);
    toast.success(`${money(net)} applied to invoice #${target.number}`);
    onClose();
  };

  const submit = async () => {
    if (!chosen || error) return;
    try {
      await applyTo(chosen);
    } catch (err) {
      if (isCheckoutOpenError(err)) {
        setHeld({ invoiceId: chosen.id, error: err });
      } else {
        setHeld(null);
        toast.error(err);
      }
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
      <p className="text-ink text-sm">
        Amount to apply: <span className="font-medium tabular-nums">{money(net)}</span>
        <span className="text-muted"> (tips never count toward an invoice)</span>
      </p>
      <FormField label="Invoice" required error={error}>
        <Select
          value={invoiceId}
          onChange={(e) => setInvoiceId(e.target.value)}
          placeholder="Choose…"
          options={invoices.data.map((i) => ({
            value: i.id,
            label: `Invoice #${i.number} · ${money(i.balance_cents)} due`,
          }))}
        />
      </FormField>
      {chosen && (
        <p className="text-muted -mt-2 text-xs">
          <Link to={`/app/invoices/${chosen.id}`} className="text-primary-ink hover:underline">
            Open invoice #{chosen.number}
          </Link>
        </p>
      )}
      {chosen && held?.invoiceId === chosen.id && (
        <CheckoutOpenNotice
          invoiceId={chosen.id}
          error={held.error}
          onRetry={() => applyTo(chosen)}
        />
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={apply.isPending}>
          Cancel
        </Button>
        <Button
          type="submit"
          variant="money"
          loading={apply.isPending}
          disabled={!chosen || Boolean(error)}
        >
          Apply {money(net)}
        </Button>
      </div>
    </form>
  );
}
