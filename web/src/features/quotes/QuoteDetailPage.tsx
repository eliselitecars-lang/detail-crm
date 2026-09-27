import { ArrowRightLeft, Copy, MoreHorizontal, Send } from 'lucide-react';
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import {
  Button,
  buttonClasses,
  ConfirmDialog,
  DropdownMenu,
  ErrorState,
  LoadingState,
  PageHeader,
  StatusBadge,
  useToast,
  type DropdownMenuEntry,
} from '@/components/ui';
import { formatLocalDate, shopToday } from '@/lib/dates';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import {
  effectiveQuoteStatus,
  isQuoteEditable,
  useDeleteQuote,
  useDuplicateQuote,
  useMarkQuoteSent,
  useQuote,
  useQuoteLineMutations,
  useQuoteLines,
  useSetQuoteStatus,
  useUpdateQuote,
  type QuoteRow,
} from './api';
import { ConvertQuoteDialog } from './components/ConvertQuoteDialog';
import { QuoteDetailsCard } from './components/QuoteDetailsCard';
import { QuoteTimeline } from './components/QuoteTimeline';
import { RecordResponseDialog } from './components/RecordResponseDialog';
import { useCustomer, useCustomerVehicles } from './shared/api';
import { DiscountEditor } from './shared/DiscountEditor';
import { copyText, publicDocUrl } from './shared/format';
import { LineItemsEditor } from './shared/LineItemsEditor';
import type { DocLine } from './shared/lines';
import { SendDocumentDialog } from './shared/SendDocumentDialog';
import { TotalsCard } from './shared/TotalsCard';

export default function QuoteDetailPage() {
  const { quoteId = '' } = useParams();
  const quote = useQuote(quoteId);
  const lines = useQuoteLines(quoteId);

  if (quote.isPending || lines.isPending) return <LoadingState label="Loading quote…" />;
  if (quote.isError || lines.isError) {
    return (
      <>
        <PageHeader title="Quote" back={{ to: '/app/quotes', label: 'Quotes' }} />
        <ErrorState
          error={quote.error ?? lines.error}
          onRetry={() => {
            void quote.refetch();
            void lines.refetch();
          }}
        />
      </>
    );
  }
  return <QuoteView quote={quote.data} lines={lines.data} />;
}

type Pending = 'send' | 'convert' | 'revise' | 'delete' | null;

function QuoteView({ quote, lines }: { quote: QuoteRow; lines: DocLine[] }) {
  const { timezone, currency } = useShop();
  const canManage = useCan('quotes.manage');
  const toast = useToast();
  const navigate = useNavigate();
  const customer = useCustomer(quote.customer_id);
  const vehicles = useCustomerVehicles(quote.customer_id);
  const update = useUpdateQuote(quote.id);
  const lineMutations = useQuoteLineMutations(quote.id, lines);
  const markSent = useMarkQuoteSent(quote.id);
  const setStatus = useSetQuoteStatus(quote.id);
  const duplicate = useDuplicateQuote();
  const remove = useDeleteQuote();
  const [pending, setPending] = useState<Pending>(null);
  const [response, setResponse] = useState<'approved' | 'declined' | null>(null);

  const today = shopToday(timezone);
  const status = effectiveQuoteStatus(quote, today);
  const editable = canManage && isQuoteEditable(quote.status);
  const vehicle = vehicles.data?.find((v) => v.id === quote.vehicle_id) ?? null;
  const link = publicDocUrl('quote', quote.public_token);
  const label = `Quote #${quote.number}`;
  const durationMinutes = lines
    .filter((line) => !line.optional || line.selected)
    .reduce((acc, line) => acc + line.duration_minutes, 0);

  const copyLink = async () => {
    if (await copyText(link)) toast.success('Client link copied');
    else toast.error('Couldn’t copy the link', link);
  };

  const runDuplicate = async () => {
    try {
      const copy = await duplicate.mutateAsync({ quote, lines });
      toast.success(`Duplicated as quote #${copy.number}`);
      await navigate(`/app/quotes/${copy.id}`);
    } catch (error) {
      toast.error(error);
    }
  };

  const menu: DropdownMenuEntry[] = [];
  if (canManage) {
    menu.push({ key: 'duplicate', label: 'Duplicate', onSelect: () => void runDuplicate() });
    if (quote.status === 'sent' || quote.status === 'viewed') {
      menu.push(
        { key: 'approve', label: 'Mark approved…', onSelect: () => setResponse('approved') },
        { key: 'decline', label: 'Mark declined…', onSelect: () => setResponse('declined') },
      );
    }
    if (quote.status !== 'draft' && quote.status !== 'converted') {
      menu.push({ key: 'revise', label: 'Revise as draft…', onSelect: () => setPending('revise') });
    }
    if (quote.status === 'draft') {
      menu.push(
        { key: 'sep', separator: true },
        {
          key: 'delete',
          label: 'Delete draft…',
          tone: 'danger',
          onSelect: () => setPending('delete'),
        },
      );
    }
  }

  const primary = (() => {
    if (!canManage) return null;
    if (quote.status === 'draft') {
      return (
        <Button
          leadingIcon={<Send className="size-4" aria-hidden="true" />}
          onClick={() => setPending('send')}
          disabled={lines.length === 0}
          title={lines.length === 0 ? 'Add at least one line item first' : undefined}
        >
          Send quote
        </Button>
      );
    }
    if ((quote.status === 'sent' || quote.status === 'viewed') && status !== 'expired') {
      return (
        <Button
          variant="secondary"
          leadingIcon={<Send className="size-4" aria-hidden="true" />}
          onClick={() => setPending('send')}
        >
          Resend
        </Button>
      );
    }
    if (quote.status === 'approved') {
      return (
        <Button
          leadingIcon={<ArrowRightLeft className="size-4" aria-hidden="true" />}
          onClick={() => setPending('convert')}
        >
          Convert to job
        </Button>
      );
    }
    if (quote.status === 'converted' && quote.converted_job_id) {
      return (
        <Link to={`/app/jobs/${quote.converted_job_id}`} className={buttonClasses()}>
          View job
        </Link>
      );
    }
    return null;
  })();

  const lockedMessage =
    quote.status === 'converted'
      ? 'This quote was converted to a job; edit the job instead.'
      : `This quote is ${status}. Revise it as a draft to change it.`;

  return (
    <>
      <PageHeader
        title={label}
        back={{ to: '/app/quotes', label: 'Quotes' }}
        meta={<StatusBadge kind="quote" status={status} />}
        description={
          quote.valid_until
            ? `Valid through ${formatLocalDate(quote.valid_until)}`
            : 'No expiry date'
        }
        actions={
          <div className="flex flex-wrap items-center gap-2">
            {primary}
            {quote.status !== 'draft' && (
              <Button
                variant="secondary"
                leadingIcon={<Copy className="size-4" aria-hidden="true" />}
                onClick={() => void copyLink()}
              >
                Copy client link
              </Button>
            )}
            {menu.length > 0 && (
              <DropdownMenu
                items={menu}
                trigger={(props) => (
                  <Button {...props} variant="secondary" aria-label="More quote actions">
                    <MoreHorizontal className="size-4" aria-hidden="true" />
                  </Button>
                )}
              />
            )}
          </div>
        }
      />

      {status === 'expired' && quote.status !== 'expired' && canManage && (
        <p
          role="status"
          className="bg-warning-soft text-warning-ink rounded-card mb-4 px-4 py-3 text-sm"
        >
          The validity date has passed, so the customer can no longer approve this quote. Choose a
          new “Valid until” date below and resend it.
        </p>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="flex min-w-0 flex-col gap-4 lg:col-span-2">
          <LineItemsEditor
            lines={lines}
            currency={currency}
            editable={editable}
            lockedMessage={lockedMessage}
            supportsOptional
            pricing={{
              customerId: quote.customer_id,
              vehicleId: quote.vehicle_id,
              vehicleCategoryId: vehicle?.category_id ?? null,
            }}
            onAdd={(drafts) => lineMutations.add.mutateAsync(drafts)}
            onUpdate={(id, patch) => lineMutations.update.mutateAsync({ id, patch })}
            onRemove={(id) => lineMutations.remove.mutateAsync(id)}
          />
          <QuoteDetailsCard
            quote={quote}
            customer={customer.data}
            editable={editable}
            today={today}
          />
        </div>
        <div className="flex min-w-0 flex-col gap-4">
          <TotalsCard
            currency={currency}
            subtotalCents={quote.subtotal_cents}
            discountCents={quote.discount_cents}
            taxCents={quote.tax_cents}
            taxRateBps={quote.tax_rate_bps}
            totalCents={quote.total_cents}
            footer={
              lines.some((l) => l.optional && !l.selected) ? (
                <p className="text-muted text-xs">
                  Optional items are not included until the customer chooses them.
                </p>
              ) : undefined
            }
          />
          <DiscountEditor
            kind={quote.discount_kind}
            value={quote.discount_value}
            currency={currency}
            editable={editable}
            onSave={(kind, value) =>
              update.mutateAsync({
                discount_kind: kind,
                discount_value: kind === 'none' ? 0 : value,
              })
            }
          />
          <QuoteTimeline quote={quote} timezone={timezone} />
        </div>
      </div>

      {customer.data && (
        <SendDocumentDialog
          open={pending === 'send'}
          onClose={() => setPending(null)}
          kind="quote"
          documentLabel={label}
          customer={customer.data}
          link={link}
          resend={quote.status !== 'draft'}
          onMarkSent={() => markSent.mutateAsync()}
        />
      )}
      <ConvertQuoteDialog
        open={pending === 'convert'}
        onClose={() => setPending(null)}
        quoteId={quote.id}
        quoteNumber={quote.number}
        durationMinutes={durationMinutes}
      />
      <RecordResponseDialog
        quoteId={quote.id}
        response={response}
        onClose={() => setResponse(null)}
        lines={lines}
        currency={currency}
      />
      <ConfirmDialog
        open={pending === 'revise'}
        onClose={() => setPending(null)}
        loading={setStatus.isPending}
        title="Revise as draft?"
        description="The quote goes back to draft so you can change it. Send it again when it’s ready; earlier responses are cleared."
        confirmLabel="Revise as draft"
        onConfirm={async () => {
          try {
            await setStatus.mutateAsync({ status: 'draft' });
            toast.success('Quote is a draft again');
            setPending(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
      <ConfirmDialog
        open={pending === 'delete'}
        onClose={() => setPending(null)}
        loading={remove.isPending}
        tone="danger"
        title={`Delete ${label.toLowerCase()}?`}
        description="This draft and its line items are deleted permanently."
        confirmLabel="Delete draft"
        onConfirm={async () => {
          try {
            await remove.mutateAsync(quote.id);
            toast.success(`${label} deleted`);
            await navigate('/app/quotes', { replace: true });
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </>
  );
}
