import { CreditCard } from 'lucide-react';
import { useState } from 'react';
import {
  Button,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  LoadingState,
  MoneyInput,
  RadioGroup,
  useToast,
} from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { EdgeFunctionError } from '@/features/quotes/shared/edge';
import { newRequestNonce } from '@/features/quotes/shared/format';
import { brandLabel } from '@/features/payments/paymentFormat';
import { useChargeSavedCard, useSavedCards } from '../api';

export interface ChargeCardDialogProps {
  open: boolean;
  onClose: () => void;
  invoiceId: string;
  invoiceNumber: number;
  customerId: string;
  balanceCents: number;
  currency: string;
  /** Opens the send dialog so the customer can pay (and authenticate) online. */
  onTextPayLink: () => void;
}

export function ChargeCardDialog(props: ChargeCardDialogProps) {
  return (
    <Dialog
      open={props.open}
      onClose={props.onClose}
      title={`Charge a saved card for invoice #${props.invoiceNumber}`}
      description="The card is charged off-session through Stripe; only the brand and last four digits are stored."
    >
      {props.open && <ChargeCardForm {...props} />}
    </Dialog>
  );
}

function ChargeCardForm({
  onClose,
  invoiceId,
  customerId,
  balanceCents,
  currency,
  onTextPayLink,
}: ChargeCardDialogProps) {
  const toast = useToast();
  const cards = useSavedCards(customerId, true);
  const charge = useChargeSavedCard(invoiceId);
  const [picked, setPicked] = useState<string | null>(null);
  const [amount, setAmount] = useState<number | null>(balanceCents);
  const [nonce, setNonce] = useState(newRequestNonce);
  const [failure, setFailure] = useState<EdgeFunctionError | null>(null);

  const list = cards.data ?? [];
  const cardId = picked ?? list[0]?.stripe_payment_method_id ?? null;
  const amountError =
    amount === null || amount <= 0
      ? 'Enter an amount greater than zero.'
      : amount > balanceCents
        ? `The amount can’t be more than the balance due (${formatCents(balanceCents, { currency })}).`
        : undefined;

  const submit = async () => {
    if (!cardId || amountError || amount === null) return;
    setFailure(null);
    try {
      const result = await charge.mutateAsync({
        paymentMethodId: cardId,
        amountCents: amount,
        nonce,
      });
      if (result.status === 'succeeded') {
        toast.success(`${formatCents(result.amount_cents, { currency })} charged`);
      } else {
        toast.info(
          'Charge is processing',
          'The invoice updates automatically when the bank confirms it.',
        );
      }
      onClose();
    } catch (error) {
      if (error instanceof EdgeFunctionError && error.status !== undefined && error.status < 500) {
        // A definitive answer (declined, needs authentication…): a new attempt is a new charge.
        setNonce(newRequestNonce());
        setFailure(error);
      } else {
        // Network/server trouble: keep the nonce so a retry cannot double-charge.
        toast.error(error);
      }
    }
  };

  if (cards.isPending) return <LoadingState label="Loading saved cards…" />;
  if (cards.isError)
    return <ErrorState compact error={cards.error} onRetry={() => void cards.refetch()} />;
  if (list.length === 0) {
    return (
      <EmptyState
        compact
        icon={<CreditCard aria-hidden="true" />}
        title="No saved card"
        description="This customer has no card on file. Send the invoice so they can pay online."
        action={
          <Button
            onClick={() => {
              onClose();
              onTextPayLink();
            }}
          >
            Send pay link
          </Button>
        }
      />
    );
  }

  const needsAuth = failure?.reason === 'authentication_required';

  return (
    <form
      noValidate
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <RadioGroup<string>
        label="Card"
        value={cardId}
        onChange={setPicked}
        options={list.map((card) => ({
          value: card.stripe_payment_method_id,
          label: `${brandLabel(card.brand)} •••• ${card.last4 ?? '????'}`,
          description: [
            card.exp_month && card.exp_year
              ? `Expires ${String(card.exp_month).padStart(2, '0')}/${card.exp_year}`
              : null,
            card.is_default ? 'Default' : null,
          ]
            .filter(Boolean)
            .join(' · '),
        }))}
      />
      <FormField
        label="Amount"
        required
        error={amount === null ? undefined : amountError}
        help={`Balance due: ${formatCents(balanceCents, { currency })}`}
      >
        <MoneyInput value={amount} onChange={setAmount} />
      </FormField>
      {failure && (
        <div
          role="alert"
          className="bg-danger-soft text-danger-ink rounded-control px-3 py-2.5 text-sm"
        >
          <p className="font-medium">
            {needsAuth
              ? 'The bank wants the customer to confirm this payment.'
              : 'The charge didn’t go through.'}
          </p>
          <p className="mt-0.5">{errorMessage(failure)}</p>
          {needsAuth && (
            <Button
              className="mt-2"
              size="sm"
              variant="secondary"
              onClick={() => {
                onClose();
                onTextPayLink();
              }}
            >
              Text the pay link
            </Button>
          )}
        </div>
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={charge.isPending}>
          Cancel
        </Button>
        <Button
          type="submit"
          variant="money"
          loading={charge.isPending}
          disabled={!cardId || Boolean(amountError)}
        >
          {amount && !amountError ? `Charge ${formatCents(amount, { currency })}` : 'Charge card'}
        </Button>
      </div>
    </form>
  );
}
