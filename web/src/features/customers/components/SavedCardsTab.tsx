import { Copy, CreditCard, MessageSquareText, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  LoadingState,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { errorMessage } from '@/lib/errors';
import { formatPhone } from '@/lib/phone';
import {
  useCreateCardSetupLink,
  useCustomerCards,
  useRemoveSavedCard,
  useSendCustomerSms,
} from '../api';
import { cardSetupMessage, type CustomerRow } from '../model';

const BRAND_LABELS: Record<string, string> = {
  visa: 'Visa',
  mastercard: 'Mastercard',
  amex: 'American Express',
  discover: 'Discover',
  diners: 'Diners Club',
  jcb: 'JCB',
  unionpay: 'UnionPay',
};

function brandLabel(brand: string | null): string {
  if (!brand) return 'Card';
  return BRAND_LABELS[brand.toLowerCase()] ?? brand.charAt(0).toUpperCase() + brand.slice(1);
}

function newNonce(): string {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `n${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`;
}

function why(customer: CustomerRow): string | null {
  if (customer.archived_at) return 'Restore this customer to send a card-setup link.';
  if (!customer.phone) return 'Add a mobile number to text a card-setup link.';
  if (customer.sms_opted_out_at) return 'This customer opted out of text messages.';
  return null;
}

interface CardToRemove {
  paymentMethodId: string;
  label: string;
}

export function SavedCardsTab({ customer }: { customer: CustomerRow }) {
  const { shopId } = useShop();
  const toast = useToast();
  const canRemove = useCan('cards.charge');
  const cards = useCustomerCards(shopId, customer.id, true);
  const removeCard = useRemoveSavedCard(shopId, customer.id);
  const [open, setOpen] = useState(false);
  const [removing, setRemoving] = useState<CardToRemove | null>(null);
  const blocked = why(customer);

  const confirmRemove = async () => {
    if (!removing) return;
    try {
      await removeCard.mutateAsync(removing.paymentMethodId);
      toast.success(`${removing.label} removed`);
      setRemoving(null);
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-muted text-sm">
          Cards are stored by Stripe. Only the brand and last four digits are kept here.
        </p>
        <Button
          variant="secondary"
          leadingIcon={<MessageSquareText className="size-4" aria-hidden="true" />}
          disabled={blocked !== null}
          title={blocked ?? undefined}
          onClick={() => setOpen(true)}
        >
          Text card-setup link
        </Button>
      </div>
      {blocked && <p className="text-muted text-xs">{blocked}</p>}

      <Card className="overflow-hidden">
        {cards.isPending ? (
          <LoadingState variant="rows" rows={2} label="Loading saved cards…" />
        ) : cards.isError ? (
          <ErrorState error={cards.error} onRetry={() => void cards.refetch()} />
        ) : cards.data.length === 0 ? (
          <EmptyState
            compact
            icon={<CreditCard aria-hidden="true" />}
            title="No saved cards"
            description="Text the customer a secure link to add one."
          />
        ) : (
          <ul className="divide-line divide-y" aria-label="Saved cards">
            {cards.data.map((card) => (
              <li
                key={card.id}
                className="flex flex-wrap items-center justify-between gap-2 px-4 py-3"
              >
                <span className="flex items-center gap-3">
                  <CreditCard className="text-muted size-5" aria-hidden="true" />
                  <span className="text-ink text-sm font-medium">
                    {brandLabel(card.brand)} ending in {card.last4 ?? '••••'}
                  </span>
                  {card.is_default && <Badge tone="info">Default</Badge>}
                </span>
                <span className="flex items-center gap-3">
                  {card.exp_month && card.exp_year && (
                    <span className="text-muted tabular text-sm">
                      Expires {String(card.exp_month).padStart(2, '0')}/
                      {String(card.exp_year).slice(-2)}
                    </span>
                  )}
                  {canRemove && (
                    <Button
                      variant="ghost"
                      size="sm"
                      leadingIcon={<Trash2 className="size-4" aria-hidden="true" />}
                      aria-label={`Remove ${brandLabel(card.brand)} ending in ${card.last4 ?? '••••'}`}
                      onClick={() =>
                        setRemoving({
                          paymentMethodId: card.stripe_payment_method_id,
                          label: `${brandLabel(card.brand)} ending in ${card.last4 ?? '••••'}`,
                        })
                      }
                    >
                      Remove
                    </Button>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}
      </Card>

      {open && <SendSetupLinkDialog customer={customer} onClose={() => setOpen(false)} />}
      <ConfirmDialog
        open={removing !== null}
        onClose={() => setRemoving(null)}
        onConfirm={confirmRemove}
        loading={removeCard.isPending}
        tone="danger"
        title="Remove saved card?"
        description={
          removing
            ? `${removing.label} is removed from this customer in Stripe and can no longer be charged. The customer can save a card again with a new link.`
            : undefined
        }
        confirmLabel="Remove card"
      />
    </div>
  );
}

function SendSetupLinkDialog({
  customer,
  onClose,
}: {
  customer: CustomerRow;
  onClose: () => void;
}) {
  const { shopId, shop } = useShop();
  const toast = useToast();
  const [nonce] = useState(newNonce);
  const [link, setLink] = useState<string | null>(null);
  const createLink = useCreateCardSetupLink(shopId, customer.id);
  const sendSms = useSendCustomerSms(shopId, customer.id);
  const busy = createLink.isPending || sendSms.isPending;

  const send = async () => {
    let url = link;
    try {
      if (!url) {
        url = (await createLink.mutateAsync(nonce)).url;
        setLink(url);
      }
      await sendSms.mutateAsync(cardSetupMessage(shop.name, customer.first_name, url));
      toast.success('Card-setup link sent', `Texted to ${formatPhone(customer.phone)}.`);
      onClose();
    } catch {
      // errors render inside the dialog
    }
  };

  const copy = async () => {
    if (!link) return;
    try {
      await navigator.clipboard.writeText(link);
      toast.success('Link copied');
    } catch {
      toast.error('Couldn’t copy. Select the link and copy it manually.');
    }
  };

  const error = createLink.error ?? sendSms.error;

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!busy}
      title="Text a card-setup link"
      description={`We’ll text ${formatPhone(customer.phone)} a secure Stripe link to save a card on file.`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            {link && sendSms.isError ? 'Close' : 'Cancel'}
          </Button>
          <Button loading={busy} onClick={() => void send()}>
            {sendSms.isError ? 'Try sending again' : 'Send text'}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        <div className="bg-surface-2 rounded-control text-ink p-3 text-sm break-words">
          {cardSetupMessage(shop.name, customer.first_name, link ?? '[secure link]')}
        </div>
        {error && (
          <p role="alert" className="text-danger-ink text-sm">
            {errorMessage(error)}
          </p>
        )}
        {link && sendSms.isError && (
          <div className="flex flex-col gap-2">
            <p className="text-muted text-sm">
              The link was created but the text didn’t go out. You can copy it and send it another
              way.
            </p>
            <div className="flex flex-col gap-2 min-[420px]:flex-row">
              <input
                readOnly
                value={link}
                aria-label="Card-setup link"
                className="border-line-strong bg-surface text-ink rounded-control h-9 min-w-0 flex-1 border px-3 text-sm"
                onFocus={(e) => e.currentTarget.select()}
              />
              <Button
                variant="secondary"
                leadingIcon={<Copy className="size-4" aria-hidden="true" />}
                onClick={() => void copy()}
              >
                Copy link
              </Button>
            </div>
          </div>
        )}
      </div>
    </Dialog>
  );
}
