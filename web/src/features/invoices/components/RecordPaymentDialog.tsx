import { zodResolver } from '@hookform/resolvers/zod';
import { Gift, Search } from 'lucide-react';
import { useMemo, useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { z } from 'zod';
import {
  Badge,
  Button,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  MoneyInput,
  RadioGroup,
  Select,
  Tabs,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { zCents, zOptionalText } from '@/lib/validation';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import {
  MANUAL_METHODS,
  METHOD_LABELS,
  type ManualMethod,
} from '@/features/payments/paymentFormat';
import {
  collectibleHelp,
  isCheckoutOpenError,
  useCustomerCredits,
  useLookupGiftCard,
  useRecordManualPayment,
  useRedeemCustomerCredit,
  useRedeemGiftCard,
  type GiftCardLookup,
} from '../api';
import { CheckoutOpenNotice } from './CheckoutOpenNotice';

export interface RecordPaymentDialogProps {
  open: boolean;
  onClose: () => void;
  invoiceId: string;
  invoiceNumber: number;
  /** The invoice's customer (their store credit can be applied). */
  customerId: string;
  /**
   * What can be collected now: the server balance less payments in flight
   * (upper bound; the RPCs re-check it).
   */
  balanceCents: number;
  /** Money in flight already subtracted from balanceCents (shown in the help text). */
  heldCents?: number;
  currency: string;
}

function schemaFor(balanceCents: number, heldCents: number, currency: string) {
  return z.object({
    method: z.enum(MANUAL_METHODS),
    amount: zCents
      .refine((v) => v > 0, 'Enter an amount greater than zero.')
      .refine(
        (v) => v <= balanceCents,
        heldCents > 0
          ? `The amount can’t be more than ${formatCents(balanceCents, { currency })} (the balance due less payments still clearing or in progress).`
          : `The amount can’t be more than the balance due (${formatCents(balanceCents, { currency })}).`,
      ),
    tip: zCents.nullable().transform((v) => v ?? 0),
    note: zOptionalText(1000),
  });
}

type FormInput = z.input<ReturnType<typeof schemaFor>>;
type FormOutput = z.output<ReturnType<typeof schemaFor>>;

type Tender = 'manual' | 'gift';

/**
 * Money received outside the card terminal: cash / check / bank transfer /
 * other (record_manual_payment), or a gift card / store credit applied as
 * tender (redeem_gift_card / redeem_customer_credit).
 */
export function RecordPaymentDialog(props: RecordPaymentDialogProps) {
  return (
    <Dialog
      open={props.open}
      onClose={props.onClose}
      title={`Record a payment on invoice #${props.invoiceNumber}`}
      description="For money received outside the card terminal. Tips never reduce the balance."
    >
      {props.open && <RecordPaymentBody {...props} />}
    </Dialog>
  );
}

function RecordPaymentBody(props: RecordPaymentDialogProps) {
  const [tender, setTender] = useState<Tender>('manual');
  return (
    <Tabs<Tender>
      label="Payment type"
      value={tender}
      onChange={setTender}
      items={[
        {
          value: 'manual',
          label: 'Cash, check, other',
          content: (
            <div className="pt-4">
              <RecordPaymentForm {...props} />
            </div>
          ),
        },
        {
          value: 'gift',
          label: 'Gift card / credit',
          content: (
            <div className="pt-4">
              <GiftCardTender {...props} />
            </div>
          ),
        },
      ]}
    />
  );
}

function RecordPaymentForm({
  onClose,
  invoiceId,
  balanceCents,
  heldCents = 0,
  currency,
}: RecordPaymentDialogProps) {
  const toast = useToast();
  const record = useRecordManualPayment(invoiceId);
  const schema = useMemo(
    () => schemaFor(balanceCents, heldCents, currency),
    [balanceCents, heldCents, currency],
  );
  const form = useForm<FormInput, unknown, FormOutput>({
    resolver: zodResolver(schema),
    defaultValues: { method: 'cash', amount: balanceCents, tip: null, note: '' },
  });
  const { errors, isSubmitting } = form.formState;
  /** Refused while a card payment page is open: offer to release it and retry. */
  const [held, setHeld] = useState<{ error: unknown; values: FormOutput } | null>(null);

  const recordValues = async (values: FormOutput) => {
    try {
      await record.mutateAsync({
        amountCents: values.amount,
        method: values.method,
        tipCents: values.tip,
        note: values.note,
      });
      setHeld(null);
      toast.success(`${formatCents(values.amount, { currency })} payment recorded`);
      onClose();
    } catch (error) {
      if (isCheckoutOpenError(error)) setHeld({ error, values });
      else {
        setHeld(null);
        toast.error(error);
      }
    }
  };

  const submit = form.handleSubmit(recordValues);

  return (
    <form noValidate className="flex flex-col gap-4" onSubmit={(event) => void submit(event)}>
      <FormField label="Method" required error={errors.method?.message}>
        <Select
          {...form.register('method')}
          options={MANUAL_METHODS.map((m: ManualMethod) => ({ value: m, label: METHOD_LABELS[m] }))}
        />
      </FormField>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <FormField
          label="Amount"
          required
          error={errors.amount?.message}
          help={collectibleHelp(balanceCents, heldCents, currency)}
        >
          <Controller
            control={form.control}
            name="amount"
            render={({ field }) => (
              <MoneyInput
                value={Number.isNaN(field.value) ? null : field.value}
                onChange={(cents) => field.onChange(cents ?? Number.NaN)}
                onBlur={field.onBlur}
                name={field.name}
              />
            )}
          />
        </FormField>
        <FormField label="Tip" error={errors.tip?.message}>
          <Controller
            control={form.control}
            name="tip"
            render={({ field }) => (
              <MoneyInput
                value={field.value}
                placeholder="0.00"
                onChange={(cents) => field.onChange(cents)}
                onBlur={field.onBlur}
                name={field.name}
              />
            )}
          />
        </FormField>
      </div>
      <FormField label="Note" error={errors.note?.message} help="Check number, reference…">
        <Textarea rows={2} {...form.register('note')} />
      </FormField>
      {held && (
        <CheckoutOpenNotice
          invoiceId={invoiceId}
          error={held.error}
          onRetry={() => recordValues(held.values)}
        />
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={isSubmitting}>
          Cancel
        </Button>
        <Button type="submit" variant="money" loading={isSubmitting}>
          Record payment
        </Button>
      </div>
    </form>
  );
}

type GiftSource = 'code' | 'credit';

function GiftCardTender(props: RecordPaymentDialogProps) {
  // Store credit rows are manager+ (RLS); technicians who collect use codes.
  const canViewCredits = useCan('giftCards.view');
  const credits = useCustomerCredits(props.customerId, canViewCredits);
  const [source, setSource] = useState<GiftSource>('code');
  const hasCredits = canViewCredits && (credits.data?.length ?? 0) > 0;

  return (
    <div className="flex flex-col gap-4">
      {hasCredits && (
        <RadioGroup<GiftSource>
          label="Pay with"
          value={source}
          onChange={setSource}
          orientation="horizontal"
          options={[
            { value: 'code', label: 'Gift card code' },
            { value: 'credit', label: 'Customer’s store credit' },
          ]}
        />
      )}
      {source === 'credit' && hasCredits ? (
        <StoreCreditForm {...props} />
      ) : (
        <GiftCodeForm {...props} />
      )}
      {canViewCredits && credits.isError && (
        <ErrorState
          compact
          title="Couldn’t load this customer’s store credit"
          error={credits.error}
          onRetry={() => void credits.refetch()}
        />
      )}
    </div>
  );
}

const CARD_STATUS_LABEL: Record<GiftCardLookup['status'], string> = {
  active: 'Active',
  depleted: 'Used up',
  void: 'Void',
  expired: 'Expired',
};

function GiftCodeForm({ invoiceId, balanceCents, currency, onClose }: RecordPaymentDialogProps) {
  const { timezone } = useShop();
  const toast = useToast();
  const lookup = useLookupGiftCard();
  const redeem = useRedeemGiftCard(invoiceId);
  const [code, setCode] = useState('');
  const [card, setCard] = useState<GiftCardLookup | null | undefined>(undefined);
  const [amount, setAmount] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  /** Refused while a card payment page is open (see CheckoutOpenNotice). */
  const [held, setHeld] = useState<unknown>(null);
  const trimmed = code.trim();
  const usable = card?.status === 'active' && card.balance_cents > 0;
  const max = card ? Math.min(card.balance_cents, balanceCents) : 0;

  const check = async () => {
    setError(null);
    if (trimmed.length < 4) {
      setError('Enter the code on the gift card.');
      return;
    }
    try {
      const found = await lookup.mutateAsync(trimmed);
      setCard(found);
      setAmount(found ? Math.min(found.balance_cents, balanceCents) : null);
    } catch (err) {
      setCard(undefined);
      setError(errorMessage(err));
    }
  };

  const apply = async () => {
    setError(null);
    if (!card || !usable) return;
    if (amount === null || amount <= 0) {
      setError('Enter an amount greater than zero.');
      return;
    }
    if (amount > max) {
      setError(`You can apply up to ${formatCents(max, { currency })}.`);
      return;
    }
    try {
      const payment = await redeem.mutateAsync({ code: trimmed, amountCents: amount });
      setHeld(null);
      if (payment === null) {
        setCard(null);
        setError('No gift card has that code.');
        return;
      }
      toast.success(`${formatCents(amount, { currency })} paid with gift card …${card.last4}`);
      onClose();
    } catch (err) {
      if (isCheckoutOpenError(err)) setHeld(err);
      else {
        setHeld(null);
        setError(errorMessage(err));
      }
    }
  };

  return (
    <form
      noValidate
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        void (usable ? apply() : check());
      }}
    >
      <FormField
        label="Gift card code"
        help="Letters and numbers, dashes optional."
        error={card === undefined ? error : null}
      >
        <div className="flex gap-2">
          <Input
            value={code}
            autoComplete="off"
            autoCapitalize="characters"
            spellCheck={false}
            maxLength={40}
            className="font-mono uppercase"
            onChange={(event) => {
              setCode(event.target.value);
              setCard(undefined);
              setError(null);
              setHeld(null);
            }}
          />
          <Button
            variant="secondary"
            loading={lookup.isPending}
            leadingIcon={<Search className="size-4" aria-hidden="true" />}
            onClick={() => void check()}
          >
            Check
          </Button>
        </div>
      </FormField>

      {card === null && (
        <p role="alert" className="text-danger-ink text-sm">
          No gift card has that code. Check it and try again.
        </p>
      )}
      {card && (
        <div className="border-line rounded-control flex flex-wrap items-center gap-3 border p-3 text-sm">
          <Gift className="text-muted size-5" aria-hidden="true" />
          <div className="min-w-0 flex-1">
            <p className="text-ink font-medium">
              {card.kind === 'credit' ? 'Store credit' : 'Gift card'} …{card.last4}
            </p>
            <p className="text-muted text-xs">
              Balance {formatCents(card.balance_cents, { currency })}
              {card.expires_at ? ` · expires ${formatDate(card.expires_at, timezone)}` : ''}
            </p>
          </div>
          <Badge tone={usable ? 'success' : 'neutral'}>{CARD_STATUS_LABEL[card.status]}</Badge>
        </div>
      )}
      {card && usable && (
        <FormField
          label="Amount to apply"
          required
          error={error}
          help={`Up to ${formatCents(max, { currency })}`}
        >
          <MoneyInput value={amount} onChange={setAmount} maxCents={max} />
        </FormField>
      )}
      {card && !usable && (
        <p className="text-muted text-sm">This card can’t be used for payment.</p>
      )}
      {held !== null && usable && (
        <CheckoutOpenNotice invoiceId={invoiceId} error={held} onRetry={apply} />
      )}

      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={redeem.isPending}>
          Cancel
        </Button>
        {usable && (
          <Button type="submit" variant="money" loading={redeem.isPending}>
            {amount ? `Apply ${formatCents(amount, { currency })}` : 'Apply gift card'}
          </Button>
        )}
      </div>
    </form>
  );
}

function StoreCreditForm({
  invoiceId,
  customerId,
  balanceCents,
  currency,
  onClose,
}: RecordPaymentDialogProps) {
  const { timezone } = useShop();
  const toast = useToast();
  const credits = useCustomerCredits(customerId, true);
  const redeem = useRedeemCustomerCredit(invoiceId);
  const list = credits.data ?? [];
  const [selectedId, setSelectedId] = useState<string>(() => list[0]?.id ?? '');
  const selected = list.find((c) => c.id === selectedId) ?? null;
  const max = selected ? Math.min(selected.balance_cents, balanceCents) : 0;
  const [amount, setAmount] = useState<number | null>(max > 0 ? max : null);
  const [error, setError] = useState<string | null>(null);
  /** Refused while a card payment page is open (see CheckoutOpenNotice). */
  const [held, setHeld] = useState<unknown>(null);

  if (credits.isPending) return <LoadingState variant="rows" rows={2} label="Loading credit…" />;
  if (list.length === 0) return <EmptyState compact title="No store credit left" />;

  const apply = async () => {
    setError(null);
    if (!selected) return;
    if (amount === null || amount <= 0) {
      setError('Enter an amount greater than zero.');
      return;
    }
    if (amount > max) {
      setError(`You can apply up to ${formatCents(max, { currency })}.`);
      return;
    }
    try {
      await redeem.mutateAsync({ giftCardId: selected.id, amountCents: amount });
      setHeld(null);
      toast.success(`${formatCents(amount, { currency })} of store credit applied`);
      onClose();
    } catch (err) {
      if (isCheckoutOpenError(err)) setHeld(err);
      else {
        setHeld(null);
        setError(errorMessage(err));
      }
    }
  };

  return (
    <form
      noValidate
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        void apply();
      }}
    >
      <RadioGroup<string>
        label="Credit"
        value={selectedId}
        onChange={(id) => {
          setSelectedId(id);
          const next = list.find((c) => c.id === id);
          setAmount(next ? Math.min(next.balance_cents, balanceCents) : null);
          setError(null);
        }}
        options={list.map((credit) => ({
          value: credit.id,
          label: `Credit …${credit.code_last4} · ${formatCents(credit.balance_cents, { currency })}`,
          description: credit.expires_at
            ? `Expires ${formatDate(credit.expires_at, timezone)}`
            : `Issued ${formatDate(credit.created_at, timezone)}`,
        }))}
      />
      <FormField
        label="Amount to apply"
        required
        error={error}
        help={`Up to ${formatCents(max, { currency })}`}
      >
        <MoneyInput value={amount} onChange={setAmount} maxCents={max} />
      </FormField>
      {held !== null && <CheckoutOpenNotice invoiceId={invoiceId} error={held} onRetry={apply} />}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={redeem.isPending}>
          Cancel
        </Button>
        <Button type="submit" variant="money" loading={redeem.isPending}>
          Apply credit
        </Button>
      </div>
    </form>
  );
}
