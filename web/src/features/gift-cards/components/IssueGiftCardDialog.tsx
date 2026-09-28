import { KeyRound } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router';
import {
  Button,
  Checkbox,
  CopyField,
  Dialog,
  FormField,
  Input,
  MoneyInput,
  RadioGroup,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import type { PickerCustomer } from '@/features/quotes/shared/api';
import { CustomerCombobox } from '@/features/quotes/shared/CustomerPicker';
import { MAX_CARD_CENTS, useIssueGiftCard, type GiftCardKind, type IssueResult } from '../api';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export interface IssueGiftCardDialogProps {
  open: boolean;
  onClose: () => void;
  /** Preselect store credit for this customer. */
  customer?: PickerCustomer | null;
}

/** Issue a gift card or store credit (issue_gift_card). The code is shown once. */
export function IssueGiftCardDialog({ open, onClose, customer = null }: IssueGiftCardDialogProps) {
  const [issued, setIssued] = useState<IssueResult | null>(null);
  const close = () => {
    setIssued(null);
    onClose();
  };
  return (
    <Dialog
      open={open}
      onClose={close}
      title={issued ? 'Gift card issued' : 'Issue a gift card'}
      description={
        issued
          ? 'Give or send this code now. For security it is never shown again.'
          : 'Sell a card at the counter, or give store credit to a customer.'
      }
      dismissible={!issued}
    >
      {open &&
        (issued ? (
          <IssuedView result={issued} onClose={close} />
        ) : (
          <IssueForm customer={customer} onIssued={setIssued} onClose={close} />
        ))}
    </Dialog>
  );
}

interface Draft {
  kind: GiftCardKind;
  amount: number | null;
  soldPrice: number | null;
  owner: PickerCustomer | null;
  name: string;
  email: string;
  message: string;
  sender: string;
  send: boolean;
}

function problems(draft: Draft, currency: string): Partial<Record<keyof Draft, string>> {
  const out: Partial<Record<keyof Draft, string>> = {};
  if (draft.amount === null || draft.amount <= 0) out.amount = 'Enter the card’s value.';
  else if (draft.amount > MAX_CARD_CENTS) {
    out.amount = `Cards can hold up to ${formatCents(MAX_CARD_CENTS, { currency })}.`;
  }
  if (draft.soldPrice !== null && draft.amount !== null && draft.soldPrice > draft.amount) {
    out.soldPrice = 'The price can’t be more than the value.';
  }
  if (draft.kind === 'credit' && !draft.owner) out.owner = 'Choose the customer the credit is for.';
  if (draft.email.trim() && !EMAIL_RE.test(draft.email.trim())) {
    out.email = 'Enter a valid email address.';
  }
  if (draft.send && !draft.email.trim()) out.email = 'Enter the email to send the card to.';
  if (draft.name.length > 120) out.name = 'Use 120 characters or fewer.';
  if (draft.sender.length > 120) out.sender = 'Use 120 characters or fewer.';
  if (draft.message.length > 500) out.message = 'Use 500 characters or fewer.';
  return out;
}

function IssueForm({
  customer,
  onIssued,
  onClose,
}: {
  customer: PickerCustomer | null;
  onIssued: (result: IssueResult) => void;
  onClose: () => void;
}) {
  const { currency } = useShop();
  const toast = useToast();
  const issue = useIssueGiftCard();
  const [draft, setDraft] = useState<Draft>({
    kind: customer ? 'credit' : 'gift',
    amount: null,
    soldPrice: null,
    owner: customer,
    name: '',
    email: '',
    message: '',
    sender: '',
    send: false,
  });
  const [submitted, setSubmitted] = useState(false);
  const errors = submitted ? problems(draft, currency) : {};
  const set = <K extends keyof Draft>(key: K, value: Draft[K]) =>
    setDraft((prev) => ({ ...prev, [key]: value }));

  const submit = async () => {
    setSubmitted(true);
    if (Object.keys(problems(draft, currency)).length > 0 || draft.amount === null) return;
    const recipient: { name?: string; email?: string; message?: string; sender_name?: string } = {};
    if (draft.name.trim()) recipient.name = draft.name.trim();
    if (draft.email.trim()) recipient.email = draft.email.trim().toLowerCase();
    if (draft.message.trim()) recipient.message = draft.message.trim();
    if (draft.sender.trim()) recipient.sender_name = draft.sender.trim();
    try {
      const result = await issue.mutateAsync({
        kind: draft.kind,
        amountCents: draft.amount,
        soldPriceCents: draft.kind === 'gift' ? draft.soldPrice : null,
        ownerCustomerId: draft.owner?.id ?? null,
        recipient,
        send: draft.send,
      });
      onIssued(result);
      if (draft.send && !result.delivery_queued) {
        toast.info(
          'The card was issued, but the email wasn’t queued',
          'Check that the gift card email template is turned on, then give the code yourself.',
        );
      }
    } catch (error) {
      toast.error(error);
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
      <RadioGroup<GiftCardKind>
        label="Type"
        value={draft.kind}
        onChange={(kind) => set('kind', kind)}
        variant="cards"
        orientation="horizontal"
        options={[
          { value: 'gift', label: 'Gift card', description: 'Anyone with the code can use it.' },
          {
            value: 'credit',
            label: 'Store credit',
            description: 'Only this customer’s invoices, no code needed.',
          },
        ]}
      />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <FormField label="Value" required error={errors.amount}>
          <MoneyInput
            value={draft.amount}
            onChange={(v) => set('amount', v)}
            maxCents={MAX_CARD_CENTS}
          />
        </FormField>
        {draft.kind === 'gift' && (
          <FormField
            label="Sold for"
            error={errors.soldPrice}
            help="Only if the buyer paid less than the value. For your records; not a payment."
          >
            <MoneyInput
              value={draft.soldPrice}
              placeholder="Same as the value"
              onChange={(v) => set('soldPrice', v)}
            />
          </FormField>
        )}
      </div>
      <FormField
        label="Customer"
        required={draft.kind === 'credit'}
        error={errors.owner}
        help={
          draft.kind === 'credit'
            ? 'The customer who can use this credit.'
            : 'Optional: who the card belongs to (for your records).'
        }
      >
        <CustomerCombobox value={draft.owner} onChange={(c) => set('owner', c)} />
      </FormField>
      <fieldset className="flex flex-col gap-3">
        <legend className="text-ink mb-1 text-sm font-medium">Recipient (optional)</legend>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <FormField label="Name" error={errors.name}>
            <Input
              value={draft.name}
              maxLength={140}
              onChange={(e) => set('name', e.target.value)}
            />
          </FormField>
          <FormField label="Email" error={errors.email}>
            <Input
              type="email"
              value={draft.email}
              maxLength={254}
              onChange={(e) => set('email', e.target.value)}
            />
          </FormField>
          <FormField label="From" error={errors.sender} help="Shown as the sender in the email.">
            <Input
              value={draft.sender}
              maxLength={140}
              onChange={(e) => set('sender', e.target.value)}
            />
          </FormField>
        </div>
        <FormField label="Message" error={errors.message}>
          <Textarea
            rows={2}
            value={draft.message}
            onChange={(e) => set('message', e.target.value)}
          />
        </FormField>
        <Checkbox
          label="Email the card to the recipient"
          description="Sends your gift card email with the code. The recipient is added as a customer if they aren’t one; their marketing preferences don’t change."
          checked={draft.send}
          onChange={(e) => set('send', e.target.checked)}
        />
      </fieldset>
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={issue.isPending}>
          Cancel
        </Button>
        <Button type="submit" variant="money" loading={issue.isPending}>
          {draft.amount ? `Issue ${formatCents(draft.amount, { currency })}` : 'Issue card'}
        </Button>
      </div>
    </form>
  );
}

function IssuedView({ result, onClose }: { result: IssueResult; onClose: () => void }) {
  const { currency } = useShop();
  return (
    <div className="flex flex-col gap-4">
      <div className="bg-money-soft text-money-ink rounded-card flex items-start gap-3 px-4 py-3 text-sm">
        <KeyRound className="size-5 shrink-0" aria-hidden="true" />
        <p>
          {formatCents(result.balance_cents, { currency })} on card …{result.last4}. Write the code
          down or copy it now: it can’t be shown again. Lost codes can’t be recovered — void the
          card and issue a new one instead.
        </p>
      </div>
      <CopyField label="Gift card code" value={result.code} copiedMessage="Code copied" />
      {result.delivery_queued && (
        <p className="text-success-ink text-sm">
          The card is on its way to the recipient by email.
        </p>
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Link
          to={`/app/gift-cards/${result.gift_card_id}`}
          className="text-primary-ink self-center text-sm font-medium hover:underline"
          onClick={onClose}
        >
          View card
        </Link>
        <Button onClick={onClose}>Done</Button>
      </div>
    </div>
  );
}
