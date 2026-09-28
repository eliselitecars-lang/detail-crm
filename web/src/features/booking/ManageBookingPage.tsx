import {
  CalendarPlus,
  CreditCard,
  FileSignature,
  FileText,
  MapPin,
  RefreshCw,
  XCircle,
} from 'lucide-react';
import { useEffect, useState } from 'react';
import { useParams, useSearchParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Badge,
  Button,
  Card,
  Dialog,
  FormField,
  KeyValueList,
  SectionCard,
  StatusBadge,
  Textarea,
  buttonClasses,
  useToast,
} from '@/components/ui';
import { formatDateTime, formatInTz, formatTimeRange } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { formatPhone } from '@/lib/phone';
import { LineList, TotalsList } from '@/features/public-docs/shared/DocumentLines';
import { timeZoneName } from '@/features/public-docs/shared/format';
import {
  Banner,
  DocumentTitle,
  PublicError,
  PublicLoading,
} from '@/features/public-docs/shared/PublicPage';
import {
  addressLines,
  isLinkToken,
  toBranding,
  vehicleLabel,
} from '@/features/public-docs/shared/schemas';
import { standardTotals } from '@/features/public-docs/shared/totals';
import {
  DEPOSIT_POLL_ATTEMPTS,
  depositSettled,
  useCancelBooking,
  useDepositCheckout,
  usePublicBooking,
  useShopProfile,
  type BookingDocument,
} from './api';
import { BookingDocumentsCard } from './components/BookingDocumentsCard';
import { BookingPageLink } from './components/BookingPageLink';
import { PublicLink } from './components/PublicLink';
import { showsBalance } from './model';
import {
  hasTracking,
  initTracking,
  stopTracking,
  trackEvent,
  useTrackingActive,
  validTrackingIds,
} from './tracking';

export default function ManageBookingPage() {
  const { token } = useParams();
  if (!isLinkToken(token)) return <PublicError error={null} what="booking" />;
  return <ManageBookingView token={token} />;
}

function ManageBookingView({ token }: { token: string }) {
  const [params] = useSearchParams();
  const paidReturn = params.get('paid') === '1';
  const canceledReturn = params.get('canceled') === '1';
  const { query, loads } = usePublicBooking(token, { pollForDeposit: paidReturn });
  if (query.isPending) return <PublicLoading label="Loading your booking…" />;
  if (query.isError) {
    return (
      <PublicError
        error={query.error}
        what="booking"
        onRetry={() => void query.refetch()}
        retrying={query.isFetching}
      />
    );
  }
  const doc = query.data;
  return (
    <BookingDocumentView
      token={token}
      doc={doc}
      paidReturn={paidReturn}
      canceledReturn={canceledReturn}
      pollingDone={depositSettled(doc) || loads >= DEPOSIT_POLL_ATTEMPTS}
      refreshing={query.isFetching}
      onRefresh={() => void query.refetch()}
    />
  );
}

const CLOSED_STATUSES = new Set(['completed', 'cancelled', 'no_show']);

function BookingDocumentView({
  token,
  doc,
  paidReturn,
  canceledReturn,
  pollingDone,
  refreshing,
  onRefresh,
}: {
  token: string;
  doc: BookingDocument;
  paidReturn: boolean;
  canceledReturn: boolean;
  pollingDone: boolean;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  const { shop, booking, deposit, totals } = doc;
  const tz = shop.timezone;
  const currency = shop.currency;
  const vehicle = vehicleLabel(doc.vehicle);
  const closed = CLOSED_STATUSES.has(booking.status);
  const where =
    booking.location_type === 'mobile'
      ? addressLines(booking.service_address ?? {})
      : addressLines(shop);
  const pendingForms = doc.forms.filter((f) => f.status === 'pending');
  useDepositPurchaseEvent(token, doc, paidReturn);
  const tracking = useTrackingActive();

  const totalRows = [
    ...standardTotals(totals),
    ...(totals.paid_cents > 0
      ? [{ key: 'paid', label: 'Paid', cents: totals.paid_cents, negative: true }]
      : []),
    ...(showsBalance(booking.status, totals.balance_cents)
      ? [
          {
            key: 'balance',
            label: 'Balance',
            cents: totals.balance_cents,
            emphasis: true,
            money: totals.balance_cents > 0,
          },
        ]
      : []),
  ];

  return (
    <PublicLayout shop={toBranding(shop)} fullPageLinks={tracking}>
      <div className="flex flex-col gap-4 sm:gap-5">
        <DocumentTitle
          title={`Booking #${booking.number}`}
          badge={<StatusBadge kind="job" status={booking.status} />}
          subtitle={`with ${shop.name}`}
        />

        {paidReturn && (
          <DepositReturnBanner
            doc={doc}
            pollingDone={pollingDone}
            refreshing={refreshing}
            onRefresh={onRefresh}
          />
        )}
        {canceledReturn && !paidReturn && deposit.status === 'due' && (
          <Banner tone="info" title="Payment cancelled">
            You weren’t charged. You can pay the deposit whenever you’re ready.
          </Banner>
        )}
        <StatusBanner doc={doc} />

        <SectionCard title="Appointment">
          <KeyValueList
            items={[
              {
                key: 'when',
                label: 'When',
                value: booking.scheduled_start ? (
                  <>
                    {formatInTz(booking.scheduled_start, tz, 'EEE, MMM d, yyyy')}
                    {booking.scheduled_end
                      ? ` · ${formatTimeRange(booking.scheduled_start, booking.scheduled_end, tz)}`
                      : ''}
                    <span className="text-muted block text-xs">
                      {timeZoneName(tz, new Date(booking.scheduled_start))}
                    </span>
                  </>
                ) : (
                  'To be scheduled'
                ),
              },
              {
                key: 'where',
                label: booking.location_type === 'mobile' ? 'Service address' : 'Location',
                value:
                  where.length > 0 ? (
                    <span className="inline-flex items-start gap-1.5">
                      <MapPin className="text-muted mt-0.5 size-3.5 shrink-0" aria-hidden="true" />
                      <span>
                        {where.map((line) => (
                          <span key={line} className="block">
                            {line}
                          </span>
                        ))}
                      </span>
                    </span>
                  ) : booking.location_type === 'mobile' ? (
                    'Your location'
                  ) : (
                    shop.name
                  ),
              },
              { key: 'vehicle', label: 'Vehicle', value: vehicle },
              ...(booking.notes
                ? [{ key: 'notes', label: 'Your notes', value: booking.notes }]
                : []),
            ]}
          />
          {doc.booking_message && !closed && (
            <p className="text-muted mt-3 text-sm whitespace-pre-line">{doc.booking_message}</p>
          )}
        </SectionCard>

        <SectionCard title="Services" flush>
          <div className="px-4 sm:px-5">
            <LineList lines={doc.line_items} currency={currency} label="Services" />
          </div>
          <div className="border-line border-t px-4 py-4 sm:px-5">
            <TotalsList currency={currency} rows={totalRows} />
          </div>
        </SectionCard>

        {deposit.status !== 'not_required' && booking.status !== 'cancelled' && (
          <DepositCard token={token} doc={doc} hidePay={paidReturn && !pollingDone} />
        )}

        {doc.forms.length > 0 && (
          <SectionCard
            title="Forms"
            description={
              pendingForms.length > 0
                ? 'Please review and sign before your appointment.'
                : undefined
            }
            flush
          >
            <ul className="divide-line divide-y px-4 sm:px-5">
              {doc.forms.map((form) => (
                <li key={form.token} className="flex items-center justify-between gap-3 py-3">
                  <div className="min-w-0">
                    <p className="text-ink text-sm font-medium break-words">{form.title}</p>
                    <p className="text-muted text-xs">
                      {form.status === 'signed'
                        ? `Signed${form.signed_at ? ` ${formatDateTime(form.signed_at, tz)}` : ''}`
                        : form.status === 'void'
                          ? 'No longer needed'
                          : form.requires_signature
                            ? 'Signature needed'
                            : 'Please review'}
                    </p>
                  </div>
                  {form.status === 'pending' ? (
                    <PublicLink
                      to={`/f/${form.token}`}
                      className={buttonClasses({ variant: 'primary', size: 'sm' })}
                    >
                      <FileSignature className="size-4" aria-hidden="true" />
                      {form.requires_signature ? 'Sign' : 'Review'}
                      <span className="sr-only"> {form.title}</span>
                    </PublicLink>
                  ) : (
                    <PublicLink
                      to={`/f/${form.token}`}
                      className={buttonClasses({ variant: 'ghost', size: 'sm' })}
                    >
                      View<span className="sr-only"> {form.title}</span>
                    </PublicLink>
                  )}
                </li>
              ))}
            </ul>
          </SectionCard>
        )}

        <BookingDocumentsCard token={token} timeZone={tz} />

        {doc.invoice && (
          <Card padded className="flex flex-wrap items-center justify-between gap-3">
            <div className="min-w-0">
              <p className="text-ink text-sm font-semibold">Invoice #{doc.invoice.number}</p>
              <p className="text-muted text-sm">
                {doc.invoice.balance_cents > 0
                  ? `${formatCents(doc.invoice.balance_cents, { currency })} due`
                  : `Total ${formatCents(doc.invoice.total_cents, { currency })}`}
              </p>
            </div>
            <PublicLink
              to={`/i/${doc.invoice.token}`}
              className={buttonClasses({
                variant: doc.invoice.balance_cents > 0 ? 'money' : 'secondary',
              })}
            >
              <FileText className="size-4" aria-hidden="true" />
              {doc.invoice.balance_cents > 0 ? 'View & pay invoice' : 'View invoice'}
            </PublicLink>
          </Card>
        )}

        <CancellationCard token={token} doc={doc} />

        {closed && (
          <BookingPageLink
            slug={shop.slug}
            className={buttonClasses({ variant: 'secondary', className: 'self-start' })}
          >
            <CalendarPlus className="size-4" aria-hidden="true" />
            Book again
          </BookingPageLink>
        )}
      </div>
    </PublicLayout>
  );
}

function StatusBanner({ doc }: { doc: BookingDocument }) {
  const { booking, shop } = doc;
  const tz = shop.timezone;
  switch (booking.status) {
    case 'requested':
      return (
        <Banner tone="info" title="Request received">
          {shop.name} will confirm your appointment soon.
        </Banner>
      );
    case 'cancelled':
      return (
        <Banner tone="warning" title="This booking was cancelled">
          {booking.cancelled_at ? `Cancelled ${formatDateTime(booking.cancelled_at, tz)}. ` : ''}
          {booking.cancel_reason ?? ''}
        </Banner>
      );
    case 'completed':
      return (
        <Banner tone="success" title="Completed">
          Thanks for choosing {shop.name}!
          {shop.review_url && (
            <>
              {' '}
              <a href={shop.review_url} target="_blank" rel="noreferrer" className="underline">
                Leave a review
              </a>
            </>
          )}
        </Banner>
      );
    case 'no_show':
      return (
        <Banner tone="warning" title="Marked as missed">
          Contact {shop.name} to rebook.
        </Banner>
      );
    default:
      return null;
  }
}

function DepositReturnBanner({
  doc,
  pollingDone,
  refreshing,
  onRefresh,
}: {
  doc: BookingDocument;
  pollingDone: boolean;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  if (depositSettled(doc)) {
    return (
      <Banner tone="success" title="Deposit received — thank you!">
        Your deposit has been recorded.
      </Banner>
    );
  }
  if (!pollingDone) {
    return (
      <Banner tone="info" title="Confirming your deposit…">
        This usually takes a few seconds. You don’t need to pay again.
      </Banner>
    );
  }
  return (
    <Banner
      tone="warning"
      title="We’re still confirming your deposit"
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
      If you completed checkout, don’t pay again — this page updates once the payment clears.
    </Banner>
  );
}

function DepositCard({
  token,
  doc,
  hidePay,
}: {
  token: string;
  doc: BookingDocument;
  hidePay: boolean;
}) {
  const checkout = useDepositCheckout(token);
  const { deposit, shop, booking } = doc;
  const currency = shop.currency;
  const canPay =
    deposit.status === 'due' &&
    deposit.card_payments_enabled &&
    !deposit.payment_pending &&
    !CLOSED_STATUSES.has(booking.status) &&
    !hidePay;
  return (
    <SectionCard
      title="Deposit"
      actions={
        deposit.status === 'paid' ? (
          <Badge tone="success" dot>
            Paid
          </Badge>
        ) : (
          <Badge tone="money" dot>
            Due
          </Badge>
        )
      }
    >
      <div className="flex flex-col gap-3">
        <KeyValueList
          items={[
            {
              key: 'required',
              label: 'Deposit',
              value: formatCents(deposit.required_cents, { currency }),
            },
            {
              key: 'paid',
              label: 'Paid',
              value: formatCents(deposit.paid_cents, { currency }),
            },
            ...(deposit.due_cents > 0
              ? [
                  {
                    key: 'due',
                    label: 'Remaining',
                    value: (
                      <span className="text-money-ink">
                        {formatCents(deposit.due_cents, { currency })}
                      </span>
                    ),
                    emphasis: true,
                  },
                ]
              : []),
          ]}
        />
        {deposit.payment_pending && deposit.status === 'due' && (
          <p className="text-muted text-sm">A payment is being processed.</p>
        )}
        {deposit.status === 'due' && !deposit.card_payments_enabled && (
          <p className="text-muted text-sm">Contact {shop.name} to pay your deposit.</p>
        )}
        {checkout.isError && (
          <Banner tone="danger" title="Couldn’t open the payment page">
            {errorMessage(checkout.error)}
          </Banner>
        )}
        {canPay && (
          <Button
            variant="money"
            size="lg"
            className="sm:self-end"
            loading={checkout.isPending || checkout.isSuccess}
            onClick={() => checkout.mutate()}
            leadingIcon={<CreditCard className="size-4" aria-hidden="true" />}
          >
            Pay {formatCents(deposit.due_cents, { currency })} deposit
          </Button>
        )}
      </div>
    </SectionCard>
  );
}

function CancellationCard({ token, doc }: { token: string; doc: BookingDocument }) {
  const toast = useToast();
  const cancel = useCancelBooking(token);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const { cancellation, booking, shop } = doc;
  const tz = shop.timezone;
  if (CLOSED_STATUSES.has(booking.status)) return null;
  const upcoming = ['requested', 'scheduled', 'confirmed'].includes(booking.status);
  if (!upcoming) return null;

  return (
    <SectionCard title="Need to cancel?">
      <div className="flex flex-col gap-3 text-sm">
        {cancellation.allowed ? (
          <p className="text-muted">
            {cancellation.deadline
              ? `You can cancel online until ${formatDateTime(cancellation.deadline, tz)}.`
              : 'You can cancel this booking online.'}
          </p>
        ) : (
          <p className="text-muted">
            Online cancellation has closed for this appointment. Please contact {shop.name}
            {shop.phone ? ` at ${formatPhone(shop.phone)}` : ''}.
          </p>
        )}
        {cancellation.policy && (
          <p className="text-muted whitespace-pre-line">{cancellation.policy}</p>
        )}
        {cancellation.allowed && (
          <Button
            variant="secondary"
            className="self-start"
            leadingIcon={<XCircle className="size-4" aria-hidden="true" />}
            onClick={() => {
              cancel.reset();
              setOpen(true);
            }}
          >
            Cancel booking
          </Button>
        )}
      </div>
      <Dialog
        open={open}
        onClose={() => setOpen(false)}
        role="alertdialog"
        title="Cancel this booking?"
        description={
          doc.deposit.paid_cents > 0
            ? `Deposits aren’t refunded automatically — contact ${shop.name} about your deposit.`
            : 'This can’t be undone online.'
        }
        dismissible={!cancel.isPending}
        footer={
          <>
            <Button variant="secondary" onClick={() => setOpen(false)} disabled={cancel.isPending}>
              Keep booking
            </Button>
            <Button
              variant="danger"
              loading={cancel.isPending}
              onClick={() =>
                cancel.mutate(reason, {
                  onSuccess: () => {
                    setOpen(false);
                    toast.success('Your booking was cancelled.');
                  },
                })
              }
            >
              Cancel booking
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-3">
          {cancel.isError && (
            <Banner tone="danger" title="Couldn’t cancel">
              {errorMessage(cancel.error)}
            </Banner>
          )}
          <FormField label="Reason (optional)">
            <Textarea
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              maxLength={1000}
              rows={3}
            />
          </FormField>
        </div>
      </Dialog>
    </SectionCard>
  );
}

const PURCHASE_SENT_KEY = 'detailcrm.booking.purchaseSent';

/**
 * GA4 'purchase' for a deposit paid through Stripe (the return to
 * ?paid=1 once the webhook has recorded it), once per booking in this
 * browser. Only the shop's GA4 tag is loaded here, with a page location that
 * has no booking token; the Meta Pixel always reports the page URL, so it is
 * never loaded on booking pages.
 */
function useDepositPurchaseEvent(token: string, doc: BookingDocument, paidReturn: boolean) {
  const profile = useShopProfile(doc.shop.slug);
  const ga4 = validTrackingIds(profile.data?.tracking).ga4MeasurementId;
  const paid = paidReturn && doc.deposit.status === 'paid' && depositSettled(doc);
  const amount = doc.deposit.paid_cents;
  const currency = doc.shop.currency;
  useEffect(() => {
    if (!paid || !ga4 || amount <= 0) return;
    const ids = { metaPixelId: null, ga4MeasurementId: ga4 };
    if (!hasTracking(ids)) return;
    let sent: string[] = [];
    try {
      const raw = sessionStorage.getItem(PURCHASE_SENT_KEY);
      const parsed: unknown = raw ? JSON.parse(raw) : [];
      sent = Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === 'string') : [];
    } catch {
      sent = [];
    }
    if (sent.includes(token)) return;
    initTracking(ids, { allowMeta: false });
    // The only event on this page: stop the tag once it is sent, so it
    // cannot record the token links or signed file links used next.
    trackEvent('deposit_paid', { valueCents: amount, currency }, { onDelivered: stopTracking });
    try {
      sessionStorage.setItem(PURCHASE_SENT_KEY, JSON.stringify([...sent, token].slice(-20)));
    } catch {
      // Storage unavailable: the event may repeat on a reload, nothing else.
    }
  }, [paid, ga4, amount, currency, token]);
}
