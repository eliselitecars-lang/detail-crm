import { CreditCard, Printer, RefreshCw } from 'lucide-react';
import { useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Button,
  Card,
  FormField,
  KeyValueList,
  MoneyInput,
  RadioGroup,
  SectionCard,
  StatusBadge,
} from '@/components/ui';
import { formatDate, formatDateTime } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import {
  PAID_POLL_ATTEMPTS,
  useInvoiceCheckout,
  usePublicInvoice,
  type InvoiceDocument,
  type InvoicePayment,
} from './api';
import { LineList, TotalsList } from './shared/DocumentLines';
import { personName } from './shared/format';
import { Banner, DocumentTitle, PublicError, PublicLoading } from './shared/PublicPage';
import { addressLines, isLinkToken, toBranding, vehicleLabel } from './shared/schemas';
import { standardTotals } from './shared/totals';
import { tipCents, type TipChoice } from './tips';

export default function InvoicePage() {
  const { token } = useParams();
  if (!isLinkToken(token)) return <PublicError error={null} what="invoice" />;
  return <InvoiceView token={token} />;
}

function InvoiceView({ token }: { token: string }) {
  const [params] = useSearchParams();
  const paidReturn = params.get('paid') === '1';
  const canceledReturn = params.get('canceled') === '1';
  const { query, loads } = usePublicInvoice(token, { pollForPayment: paidReturn });
  if (query.isPending) return <PublicLoading label="Loading invoice…" />;
  if (query.isError) {
    return (
      <PublicError
        error={query.error}
        what="invoice"
        onRetry={() => void query.refetch()}
        retrying={query.isFetching}
      />
    );
  }
  const doc = query.data;
  const settled = doc.invoice.status === 'paid' || !doc.invoice.payable;
  const pollingDone = settled || loads >= PAID_POLL_ATTEMPTS;
  return (
    <InvoiceDocumentView
      token={token}
      doc={doc}
      paidReturn={paidReturn}
      canceledReturn={canceledReturn}
      pollingDone={pollingDone}
      refreshing={query.isFetching}
      onRefresh={() => void query.refetch()}
    />
  );
}

function InvoiceDocumentView({
  token,
  doc,
  paidReturn,
  canceledReturn,
  pollingDone,
  refreshing,
  onRefresh,
}: {
  token: string;
  doc: InvoiceDocument;
  paidReturn: boolean;
  canceledReturn: boolean;
  pollingDone: boolean;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  const { shop, invoice } = doc;
  const currency = shop.currency;
  const tz = shop.timezone;
  const customer = personName(doc.customer);
  const vehicle = vehicleLabel(doc.vehicle);
  const shopAddress = addressLines(shop);
  const canPayOnline = invoice.payable && invoice.card_payments_enabled && !paidReturn;

  const totals = [
    ...standardTotals(invoice),
    ...(invoice.amount_paid_cents > 0
      ? [
          {
            key: 'paid',
            label: 'Paid',
            cents: invoice.amount_paid_cents,
            negative: true,
          },
        ]
      : []),
    {
      key: 'balance',
      label: 'Balance due',
      cents: invoice.balance_cents,
      emphasis: true,
      money: invoice.balance_cents > 0 && invoice.status !== 'void',
    },
  ];

  return (
    <PublicLayout shop={toBranding(shop)}>
      {/* Printable: actions/banners are print:hidden; cards print flat and unsplit. */}
      <div className="flex flex-col gap-4 sm:gap-5 print:gap-3 print:text-black print:[&_*]:shadow-none print:[&>*]:break-inside-avoid">
        <DocumentTitle
          title={`Invoice #${invoice.number}`}
          badge={<StatusBadge kind="invoice" status={invoice.status} />}
          subtitle={[
            invoice.issued_at ? `Issued ${formatDate(invoice.issued_at, tz)}` : null,
            invoice.due_at && invoice.balance_cents > 0 && invoice.status !== 'void'
              ? `Due ${formatDate(invoice.due_at, tz)}`
              : null,
          ]
            .filter(Boolean)
            .join(' · ')}
          actions={
            <Button
              variant="secondary"
              leadingIcon={<Printer className="size-4" aria-hidden="true" />}
              onClick={() => window.print()}
            >
              Print
            </Button>
          }
        />

        {paidReturn && (
          <PaidReturnBanner
            doc={doc}
            pollingDone={pollingDone}
            refreshing={refreshing}
            onRefresh={onRefresh}
            token={token}
          />
        )}
        {canceledReturn && !paidReturn && invoice.payable && (
          <Banner tone="info" title="Payment cancelled">
            You weren’t charged. You can pay whenever you’re ready.
          </Banner>
        )}
        {invoice.status === 'void' && (
          <Banner tone="warning" title="This invoice was voided">
            {invoice.voided_at ? `Voided on ${formatDate(invoice.voided_at, tz)}. ` : ''}
            Nothing is owed on it. Contact {shop.name} with any questions.
          </Banner>
        )}
        {invoice.status === 'paid' && !paidReturn && (
          <Banner tone="success" title="Paid in full">
            {invoice.paid_at ? `Paid on ${formatDate(invoice.paid_at, tz)}. ` : ''}Thank you!
          </Banner>
        )}

        <Card padded className="grid gap-4 sm:grid-cols-2">
          <div>
            <p className="text-muted text-xs font-medium">From</p>
            <p className="text-ink text-sm font-semibold">{shop.name}</p>
            {shopAddress.map((line) => (
              <p key={line} className="text-muted text-sm">
                {line}
              </p>
            ))}
          </div>
          <div>
            <p className="text-muted text-xs font-medium">Billed to</p>
            <p className="text-ink text-sm font-semibold">{customer ?? '—'}</p>
            {doc.job && (
              <p className="text-muted text-sm">
                Appointment #{doc.job.number}
                {doc.job.scheduled_start ? ` · ${formatDate(doc.job.scheduled_start, tz)}` : ''}
              </p>
            )}
            {vehicle && <p className="text-muted text-sm">{vehicle}</p>}
          </div>
        </Card>

        <SectionCard title="Items" flush>
          <div className="px-4 sm:px-5">
            <LineList lines={doc.line_items} currency={currency} label="Invoice items" />
          </div>
        </SectionCard>

        <Card padded>
          <TotalsList currency={currency} rows={totals} />
          {invoice.tip_cents > 0 && (
            <p className="text-muted mt-3 text-xs">
              Tips received: {formatCents(invoice.tip_cents, { currency })} (not part of the
              balance). Thank you!
            </p>
          )}
        </Card>

        {canPayOnline && (
          <PayPanel token={token} balanceCents={invoice.balance_cents} currency={currency} />
        )}
        {invoice.payable && !invoice.card_payments_enabled && (
          <Banner tone="info" title="Online payment isn’t available">
            Please contact {shop.name} to pay this invoice.
          </Banner>
        )}

        {doc.payments.length > 0 && (
          <SectionCard title="Payments received" flush>
            <ul aria-label="Payments received" className="divide-line divide-y px-4 sm:px-5">
              {doc.payments.map((payment, i) => (
                <PaymentRow key={i} payment={payment} currency={currency} timeZone={tz} />
              ))}
            </ul>
          </SectionCard>
        )}

        {(invoice.notes || invoice.terms) && (
          <SectionCard title="Notes & terms">
            <div className="text-ink flex flex-col gap-3 text-sm break-words whitespace-pre-line">
              {invoice.notes && <p>{invoice.notes}</p>}
              {invoice.terms && <p className="text-muted">{invoice.terms}</p>}
            </div>
          </SectionCard>
        )}
      </div>
    </PublicLayout>
  );
}

function PaidReturnBanner({
  doc,
  pollingDone,
  refreshing,
  onRefresh,
  token,
}: {
  doc: InvoiceDocument;
  pollingDone: boolean;
  refreshing: boolean;
  onRefresh: () => void;
  token: string;
}) {
  const { invoice, shop } = doc;
  if (invoice.status === 'paid') {
    return (
      <Banner tone="success" title="Payment received — thank you!">
        This invoice is paid in full. A receipt is on its way from {shop.name}.
      </Banner>
    );
  }
  if (!pollingDone) {
    return (
      <Banner tone="info" title="Confirming your payment…">
        This usually takes a few seconds. You don’t need to pay again.
      </Banner>
    );
  }
  if (!invoice.payable) {
    return (
      <Banner tone="success" title="Payment received — thank you!">
        Your payment has been recorded.
      </Banner>
    );
  }
  return (
    <Banner
      tone="warning"
      title="We’re still confirming your payment"
      action={
        <Button
          size="sm"
          variant="secondary"
          loading={refreshing}
          leadingIcon={<RefreshCw className="size-4" aria-hidden="true" />}
          onClick={onRefresh}
        >
          Check again
        </Button>
      }
    >
      If you completed checkout, don’t pay again — the balance updates once the payment clears.{' '}
      <Link to={`/i/${token}`} className="underline">
        Pay a remaining balance
      </Link>
    </Banner>
  );
}

const TIP_OPTIONS: { value: TipChoice; label: string }[] = [
  { value: 'none', label: 'No tip' },
  { value: '15', label: '15%' },
  { value: '20', label: '20%' },
  { value: 'custom', label: 'Custom' },
];

function PayPanel({
  token,
  balanceCents,
  currency,
}: {
  token: string;
  balanceCents: number;
  currency: string;
}) {
  const checkout = useInvoiceCheckout(token);
  const [choice, setChoice] = useState<TipChoice>('none');
  const [custom, setCustom] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const tip = tipCents(choice, balanceCents, custom);

  const pay = () => {
    if (tip === null) {
      setError(
        `Enter a tip between ${formatCents(0, { currency })} and ${formatCents(balanceCents, { currency })}.`,
      );
      return;
    }
    setError(null);
    checkout.mutate(tip);
  };

  return (
    <SectionCard
      title="Pay online"
      description="Secure card payment by Stripe. Tips go to the team and don’t change your balance."
      className="print:hidden"
    >
      <div className="flex flex-col gap-4">
        <RadioGroup<TipChoice>
          label="Add a tip"
          value={choice}
          onChange={(value) => {
            setChoice(value);
            setError(null);
          }}
          options={TIP_OPTIONS.map((option) => ({
            value: option.value,
            label: option.label,
            ...(option.value === '15' || option.value === '20'
              ? {
                  description: formatCents(tipCents(option.value, balanceCents, null), {
                    currency,
                  }),
                }
              : {}),
          }))}
          variant="cards"
          orientation="horizontal"
          className="[&>div]:grid-cols-2 [&>div]:sm:grid-cols-4"
        />
        {choice === 'custom' && (
          <FormField
            label="Tip amount"
            error={error}
            help={`Up to ${formatCents(balanceCents, { currency })}`}
          >
            <MoneyInput value={custom} onChange={setCustom} maxCents={balanceCents} />
          </FormField>
        )}
        {checkout.isError && (
          <Banner tone="danger" title="Couldn’t start the payment">
            {errorMessage(checkout.error)}
          </Banner>
        )}
        <KeyValueList
          items={[
            { key: 'balance', label: 'Balance', value: formatCents(balanceCents, { currency }) },
            {
              key: 'tip',
              label: 'Tip',
              value: tip === null ? '—' : formatCents(tip, { currency }),
            },
          ]}
        />
        <Button
          variant="money"
          size="lg"
          fullWidth
          loading={checkout.isPending || checkout.isSuccess}
          leadingIcon={<CreditCard className="size-4" aria-hidden="true" />}
          onClick={pay}
        >
          {`Pay ${formatCents(balanceCents, { currency })}${tip ? ` + ${formatCents(tip, { currency })} tip` : ''}`}
        </Button>
      </div>
    </SectionCard>
  );
}

const METHOD_LABELS: Record<InvoicePayment['method'], string> = {
  card: 'Card',
  card_present: 'Card (in person)',
  cash: 'Cash',
  check: 'Check',
  bank_transfer: 'Bank transfer',
  other: 'Other',
};

function PaymentRow({
  payment,
  currency,
  timeZone,
}: {
  payment: InvoicePayment;
  currency: string;
  timeZone: string;
}) {
  const card =
    payment.card_brand && payment.card_last4
      ? `${payment.card_brand.charAt(0).toUpperCase()}${payment.card_brand.slice(1)} •••• ${payment.card_last4}`
      : METHOD_LABELS[payment.method];
  const details = [
    payment.kind === 'deposit' ? 'Deposit' : null,
    payment.paid_at ? formatDateTime(payment.paid_at, timeZone) : null,
    payment.tip_cents > 0 ? `+ ${formatCents(payment.tip_cents, { currency })} tip` : null,
    payment.refunded_cents > 0
      ? `${formatCents(payment.refunded_cents, { currency })} refunded`
      : null,
  ].filter(Boolean);
  return (
    <li className="flex items-start justify-between gap-3 py-3">
      <div className="min-w-0">
        <p className="text-ink text-sm font-medium">{card}</p>
        <p className="text-muted text-xs">{details.join(' · ')}</p>
      </div>
      <div className="flex shrink-0 flex-col items-end gap-1">
        <p className="text-ink text-sm font-medium tabular-nums">
          {formatCents(payment.amount_cents, { currency })}
        </p>
        {payment.status !== 'succeeded' && <StatusBadge kind="payment" status={payment.status} />}
      </div>
    </li>
  );
}
