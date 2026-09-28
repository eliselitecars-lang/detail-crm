import { Ban, Scale } from 'lucide-react';
import { useState } from 'react';
import { Link, useParams } from 'react-router';
import {
  Button,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  KeyValueList,
  LoadingState,
  MoneyInput,
  PageHeader,
  RadioGroup,
  SectionCard,
  Textarea,
  useToast,
  type KeyValueItem,
} from '@/components/ui';
import { formatDate, formatDateTime } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import { customerName } from '@/features/quotes/shared/format';
import {
  effectiveCardStatus,
  ISSUED_VIA_LABELS,
  KIND_LABELS,
  MAX_CARD_CENTS,
  TXN_LABELS,
  useAdjustGiftCard,
  useGiftCard,
  useVoidGiftCard,
  type GiftCardDetail,
  type GiftCardRow,
} from './api';
import { CardStatusBadge } from './components/CardStatusBadge';

export default function GiftCardDetailPage() {
  const { giftCardId = '' } = useParams();
  const detail = useGiftCard(giftCardId);
  if (detail.isPending) return <LoadingState label="Loading gift card…" />;
  if (detail.isError) {
    const notFound = toAppError(detail.error).kind === 'not_found';
    return (
      <>
        <PageHeader title="Gift card" back={{ to: '/app/gift-cards', label: 'Gift cards' }} />
        {notFound ? (
          <EmptyState title="Gift card not found" description="It may have been removed." />
        ) : (
          <ErrorState error={detail.error} onRetry={() => void detail.refetch()} />
        )}
      </>
    );
  }
  return <GiftCardView detail={detail.data} />;
}

function GiftCardView({ detail }: { detail: GiftCardDetail }) {
  const { card, transactions } = detail;
  const { timezone, currency } = useShop();
  const canAdjust = useCan('giftCards.adjust');
  const [dialog, setDialog] = useState<'adjust' | 'void' | null>(null);
  const status = effectiveCardStatus(card);
  const money = (cents: number) => formatCents(cents, { currency });

  const items: KeyValueItem[] = [
    { key: 'kind', label: 'Type', value: KIND_LABELS[card.kind] },
    {
      key: 'value',
      label: 'Value',
      value: <span className="tabular">{money(card.initial_cents)}</span>,
    },
    {
      key: 'balance',
      label: 'Balance',
      emphasis: true,
      value: <span className="tabular">{money(card.balance_cents)}</span>,
    },
    ...(card.sold_price_cents !== null && card.sold_price_cents !== card.initial_cents
      ? [
          {
            key: 'sold',
            label: 'Sold for',
            value: <span className="tabular">{money(card.sold_price_cents)}</span>,
          },
        ]
      : []),
    { key: 'via', label: 'Source', value: ISSUED_VIA_LABELS[card.issued_via] ?? card.issued_via },
    { key: 'issued', label: 'Issued', value: formatDate(card.created_at, timezone) },
    {
      key: 'expires',
      label: 'Expires',
      value: card.expires_at ? formatDate(card.expires_at, timezone) : 'Never',
    },
    ...(card.owner
      ? [
          {
            key: 'owner',
            label: card.kind === 'credit' ? 'Belongs to' : 'Customer',
            value: <CustomerLink person={card.owner} />,
          },
        ]
      : []),
    ...(card.purchaser && card.purchaser.id !== card.owner?.id
      ? [{ key: 'purchaser', label: 'Bought by', value: <CustomerLink person={card.purchaser} /> }]
      : []),
    ...(card.recipient_name || card.recipient_email
      ? [
          {
            key: 'recipient',
            label: 'Recipient',
            value: [card.recipient_name, card.recipient_email].filter(Boolean).join(' · '),
          },
        ]
      : []),
    ...(card.voided_at
      ? [
          { key: 'voided', label: 'Voided', value: formatDate(card.voided_at, timezone) },
          ...(card.void_reason
            ? [{ key: 'reason', label: 'Reason', value: card.void_reason }]
            : []),
        ]
      : []),
  ];

  return (
    <>
      <PageHeader
        title={`${KIND_LABELS[card.kind]} …${card.code_last4}`}
        back={{ to: '/app/gift-cards', label: 'Gift cards' }}
        meta={<CardStatusBadge status={status} />}
        actions={
          canAdjust && card.status !== 'void' ? (
            <div className="flex flex-wrap gap-2">
              <Button
                variant="secondary"
                leadingIcon={<Scale className="size-4" aria-hidden="true" />}
                onClick={() => setDialog('adjust')}
              >
                Adjust balance
              </Button>
              <Button
                variant="danger"
                leadingIcon={<Ban className="size-4" aria-hidden="true" />}
                onClick={() => setDialog('void')}
              >
                Void card
              </Button>
            </div>
          ) : undefined
        }
      />
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <SectionCard title="Details">
          <div className="flex flex-col gap-3">
            <KeyValueList items={items} />
            {card.message && (
              <div>
                <p className="text-muted text-xs font-medium">Message</p>
                <p className="text-ink text-sm whitespace-pre-line">{card.message}</p>
              </div>
            )}
          </div>
        </SectionCard>
        <SectionCard title="History" flush className="lg:col-span-2">
          {transactions.length === 0 ? (
            <EmptyState compact title="No activity yet" />
          ) : (
            <ul className="divide-line divide-y" aria-label="Card history">
              {transactions.map((txn) => (
                <li key={txn.id} className="flex flex-wrap items-start gap-3 px-4 py-3">
                  <div className="min-w-0 flex-1">
                    <p className="text-ink text-sm font-medium">{TXN_LABELS[txn.kind]}</p>
                    <p className="text-muted text-xs">
                      {formatDateTime(txn.created_at, timezone)}
                      {txn.payment?.invoice ? (
                        <>
                          {' · '}
                          <Link
                            to={`/app/invoices/${txn.payment.invoice.id}`}
                            className="text-primary-ink hover:underline"
                          >
                            Invoice #{txn.payment.invoice.number}
                          </Link>
                        </>
                      ) : null}
                    </p>
                    {txn.note && (
                      <p className="text-muted mt-0.5 text-xs break-words">{txn.note}</p>
                    )}
                  </div>
                  <div className="flex shrink-0 flex-col items-end">
                    <span
                      className={
                        txn.amount_cents < 0
                          ? 'text-danger-ink text-sm font-medium tabular-nums'
                          : 'text-ink text-sm font-medium tabular-nums'
                      }
                    >
                      {txn.amount_cents > 0 ? '+' : txn.amount_cents < 0 ? '−' : ''}
                      {money(Math.abs(txn.amount_cents))}
                    </span>
                    <span className="text-muted text-xs tabular-nums">
                      Balance {money(txn.balance_after_cents)}
                    </span>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </SectionCard>
      </div>
      {canAdjust && (
        <>
          <AdjustDialog card={card} open={dialog === 'adjust'} onClose={() => setDialog(null)} />
          <VoidDialog card={card} open={dialog === 'void'} onClose={() => setDialog(null)} />
        </>
      )}
    </>
  );
}

function CustomerLink({ person }: { person: NonNullable<GiftCardRow['owner']> }) {
  return (
    <Link to={`/app/customers/${person.id}`} className="text-primary-ink hover:underline">
      {customerName(person)}
    </Link>
  );
}

function AdjustDialog({
  card,
  open,
  onClose,
}: {
  card: GiftCardRow;
  open: boolean;
  onClose: () => void;
}) {
  return (
    <Dialog
      open={open}
      onClose={onClose}
      size="sm"
      title="Adjust balance"
      description="Corrects the balance (for example a lost receipt or a goodwill top-up). It is recorded in the card’s history."
    >
      {open && <AdjustForm card={card} onClose={onClose} />}
    </Dialog>
  );
}

function AdjustForm({ card, onClose }: { card: GiftCardRow; onClose: () => void }) {
  const { currency } = useShop();
  const toast = useToast();
  const adjust = useAdjustGiftCard(card.id);
  const [direction, setDirection] = useState<'add' | 'remove'>('add');
  const [amount, setAmount] = useState<number | null>(null);
  const [note, setNote] = useState('');
  const [error, setError] = useState<string | null>(null);
  const max = direction === 'remove' ? card.balance_cents : MAX_CARD_CENTS - card.balance_cents;

  const submit = async () => {
    setError(null);
    if (amount === null || amount <= 0) {
      setError('Enter an amount greater than zero.');
      return;
    }
    if (amount > max) {
      setError(
        direction === 'remove'
          ? `You can remove up to ${formatCents(max, { currency })}.`
          : `The balance can’t go over ${formatCents(MAX_CARD_CENTS, { currency })}.`,
      );
      return;
    }
    if (note.length > 500) {
      setError('The note can be at most 500 characters.');
      return;
    }
    try {
      await adjust.mutateAsync({
        deltaCents: direction === 'add' ? amount : -amount,
        note: note.trim() || null,
      });
      toast.success('Balance adjusted');
      onClose();
    } catch (err) {
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
      <RadioGroup<'add' | 'remove'>
        label="Change"
        value={direction}
        onChange={setDirection}
        orientation="horizontal"
        options={[
          { value: 'add', label: 'Add to balance' },
          { value: 'remove', label: 'Remove from balance' },
        ]}
      />
      <FormField
        label="Amount"
        required
        error={error}
        help={`Current balance ${formatCents(card.balance_cents, { currency })}`}
      >
        <MoneyInput value={amount} onChange={setAmount} maxCents={Math.max(0, max)} />
      </FormField>
      <FormField label="Note" help="Why the balance changed (kept in the history).">
        <Textarea rows={2} value={note} onChange={(e) => setNote(e.target.value)} />
      </FormField>
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={adjust.isPending}>
          Cancel
        </Button>
        <Button type="submit" loading={adjust.isPending}>
          Save adjustment
        </Button>
      </div>
    </form>
  );
}

function VoidDialog({
  card,
  open,
  onClose,
}: {
  card: GiftCardRow;
  open: boolean;
  onClose: () => void;
}) {
  const { currency } = useShop();
  const toast = useToast();
  const voidCard = useVoidGiftCard(card.id);
  const [reason, setReason] = useState('');
  return (
    <ConfirmDialog
      open={open}
      onClose={onClose}
      loading={voidCard.isPending}
      tone="danger"
      title={`Void card …${card.code_last4}?`}
      description={`The remaining ${formatCents(card.balance_cents, { currency })} is taken off for good and the code stops working. Payments already made with it stay.`}
      confirmLabel="Void card"
      onConfirm={async () => {
        if (reason.length > 500) return;
        try {
          await voidCard.mutateAsync(reason.trim() || null);
          toast.success('Card voided');
          setReason('');
          onClose();
        } catch (error) {
          toast.error(error);
        }
      }}
    >
      <FormField
        label="Reason"
        help="Optional."
        error={reason.length > 500 ? 'Use 500 characters or fewer.' : undefined}
      >
        <Textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
      </FormField>
    </ConfirmDialog>
  );
}
