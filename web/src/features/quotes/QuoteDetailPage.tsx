import { ArrowRightLeft, CalendarCheck, Copy, FileDown, MoreHorizontal, Send } from 'lucide-react';
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import { useQueryClient } from '@tanstack/react-query';
import {
  Button,
  buttonClasses,
  ConfirmDialog,
  DropdownMenu,
  ErrorState,
  LoadingState,
  PageHeader,
  StatusBadge,
  Tabs,
  useToast,
  type DropdownMenuEntry,
} from '@/components/ui';
import { formatDateTime, formatLocalDate, shopToday } from '@/lib/dates';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import {
  effectiveOptionId,
  effectiveQuoteStatus,
  isQuoteEditable,
  quoteKeys,
  useDeleteQuote,
  useDuplicateQuote,
  useMarkQuoteSent,
  useQuote,
  useQuoteLineMutations,
  useQuoteLines,
  useQuoteOptions,
  useSetQuoteStatus,
  useUpdateQuote,
  type QuoteOptionRow,
  type QuoteRow,
} from './api';
import { ConvertQuoteDialog } from './components/ConvertQuoteDialog';
import { QuoteDetailsCard } from './components/QuoteDetailsCard';
import { QuoteOptionsCard } from './components/QuoteOptionsCard';
import { QuoteTimeline } from './components/QuoteTimeline';
import { RecordResponseDialog } from './components/RecordResponseDialog';
import { useCustomer, useCustomerVehicles } from './shared/api';
import { DiscountEditor } from './shared/DiscountEditor';
import { useAddFeeLine } from './shared/fees';
import { FollowupStatusCard } from './shared/FollowupStatusCard';
import { copyText, publicDocUrl } from './shared/format';
import { LineItemsEditor, type LineItemsEditorProps } from './shared/LineItemsEditor';
import { countedLines, type DocLine } from './shared/lines';
import { useStaffPdf } from './shared/pdf';
import { SendDocumentDialog } from './shared/SendDocumentDialog';
import { TotalsCard } from './shared/TotalsCard';

export default function QuoteDetailPage() {
  const { quoteId = '' } = useParams();
  const quote = useQuote(quoteId);
  const lines = useQuoteLines(quoteId);
  const options = useQuoteOptions(quoteId);

  if (quote.isPending || lines.isPending || options.isPending) {
    return <LoadingState label="Loading quote…" />;
  }
  if (quote.isError || lines.isError || options.isError) {
    return (
      <>
        <PageHeader title="Quote" back={{ to: '/app/quotes', label: 'Quotes' }} />
        <ErrorState
          error={quote.error ?? lines.error ?? options.error}
          onRetry={() => {
            void quote.refetch();
            void lines.refetch();
            void options.refetch();
          }}
        />
      </>
    );
  }
  return <QuoteView quote={quote.data} lines={lines.data} options={options.data} />;
}

type Pending = 'send' | 'convert' | 'revise' | 'delete' | null;

function QuoteView({
  quote,
  lines,
  options,
}: {
  quote: QuoteRow;
  lines: DocLine[];
  options: QuoteOptionRow[];
}) {
  const { shopId, timezone, currency } = useShop();
  const canManage = useCan('quotes.manage');
  const toast = useToast();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const customer = useCustomer(quote.customer_id);
  const vehicles = useCustomerVehicles(quote.customer_id);
  const update = useUpdateQuote(quote.id);
  const lineMutations = useQuoteLineMutations(quote.id, lines);
  const markSent = useMarkQuoteSent(quote.id);
  const setStatus = useSetQuoteStatus(quote.id);
  const duplicate = useDuplicateQuote();
  const remove = useDeleteQuote();
  const pdf = useStaffPdf();
  const addFee = useAddFeeLine('quote', quote.id, () =>
    queryClient.invalidateQueries({ queryKey: quoteKeys.all(shopId) }),
  );
  const [pending, setPending] = useState<Pending>(null);
  const [response, setResponse] = useState<'approved' | 'declined' | null>(null);
  const [tab, setTab] = useState<string | null>(null);

  const today = shopToday(timezone);
  const status = effectiveQuoteStatus(quote, today);
  const editable = canManage && isQuoteEditable(quote.status);
  const vehicle = vehicles.data?.find((v) => v.id === quote.vehicle_id) ?? null;
  const link = publicDocUrl('quote', quote.public_token);
  const label = `Quote #${quote.number}`;
  const hasOptions = options.length > 0;
  const effectiveId = effectiveOptionId(quote, options);
  const effectiveOption = options.find((o) => o.id === effectiveId) ?? null;
  const durationMinutes = countedLines(lines, effectiveId).reduce(
    (acc, line) => acc + line.duration_minutes,
    0,
  );
  const activeTab = options.find((o) => o.id === tab)?.id ?? options[0]?.id ?? null;
  const optionChoices = options.map((o) => ({ id: o.id, name: o.name }));
  const selfScheduled = quote.self_scheduled_at !== null;

  const copyLink = async () => {
    if (await copyText(link)) toast.success('Client link copied');
    else toast.error('Couldn’t copy the link', link);
  };

  const downloadPdf = async () => {
    try {
      await pdf.mutateAsync({ kind: 'quote', id: quote.id, number: quote.number });
    } catch (error) {
      toast.error(error);
    }
  };

  const runDuplicate = async () => {
    try {
      const copy = await duplicate.mutateAsync({ quote, lines, options });
      toast.success(`Duplicated as quote #${copy.number}`);
      await navigate(`/app/quotes/${copy.id}`);
    } catch (error) {
      toast.error(error);
    }
  };

  const menu: DropdownMenuEntry[] = [
    {
      key: 'pdf',
      label: 'Download PDF',
      icon: <FileDown className="size-4" aria-hidden="true" />,
      disabled: pdf.isPending,
      onSelect: () => void downloadPdf(),
    },
  ];
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

  const editorBase: Omit<LineItemsEditorProps, 'lines'> = {
    currency,
    editable,
    lockedMessage,
    supportsOptional: true,
    pricing: {
      customerId: quote.customer_id,
      vehicleId: quote.vehicle_id,
      vehicleCategoryId: vehicle?.category_id ?? null,
    },
    vehicles: vehicles.data ?? [],
    documentDiscounted: quote.discount_cents > 0,
    onAdd: (drafts) => lineMutations.add.mutateAsync(drafts),
    onUpdate: (id, patch) => lineMutations.update.mutateAsync({ id, patch }),
    onRemove: (id) => lineMutations.remove.mutateAsync(id),
    ...(hasOptions ? { options: optionChoices } : {}),
  };

  const sharedLines = lines.filter((line) => line.option_id === null);

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
            <DropdownMenu
              items={menu}
              trigger={(props) => (
                <Button {...props} variant="secondary" aria-label="More quote actions">
                  <MoreHorizontal className="size-4" aria-hidden="true" />
                </Button>
              )}
            />
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
      {quote.status === 'converted' && selfScheduled && (
        <p
          role="status"
          className="bg-success-soft text-success-ink rounded-card mb-4 flex flex-wrap items-center gap-2 px-4 py-3 text-sm"
        >
          <CalendarCheck className="size-4 shrink-0" aria-hidden="true" />
          <span>
            Scheduled by the customer
            {quote.self_scheduled_at
              ? ` on ${formatDateTime(quote.self_scheduled_at, timezone)}`
              : ''}
            .
          </span>
          {quote.converted_job_id && (
            <Link
              to={`/app/jobs/${quote.converted_job_id}`}
              className="font-medium underline underline-offset-2"
            >
              Open the job
            </Link>
          )}
        </p>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="flex min-w-0 flex-col gap-4 lg:col-span-2">
          {(hasOptions || editable) && (
            <QuoteOptionsCard
              quote={quote}
              options={options}
              effectiveOptionId={effectiveId}
              editable={editable}
              currency={currency}
            />
          )}
          {hasOptions ? (
            <>
              <LineItemsEditor
                {...editorBase}
                lines={sharedLines}
                title="Included in every option"
                listLabel="Shared line items"
                defaultOptionId={null}
                onAddFee={(feeId) => addFee.mutateAsync(feeId)}
                emptyDescription="Lines here are part of every option. Add option-specific lines in the tabs below."
              />
              <Tabs
                label="Option lines"
                value={activeTab ?? ''}
                onChange={setTab}
                items={options.map((option) => ({
                  value: option.id,
                  label: option.name,
                  count: lines.filter((l) => l.option_id === option.id).length,
                  content: (
                    <div className="pt-4">
                      <LineItemsEditor
                        {...editorBase}
                        lines={lines.filter((l) => l.option_id === option.id)}
                        title={`${option.name} lines`}
                        listLabel={`${option.name} line items`}
                        defaultOptionId={option.id}
                        emptyDescription={`Add what ${option.name} includes on top of the shared lines.`}
                      />
                    </div>
                  ),
                }))}
              />
            </>
          ) : (
            <LineItemsEditor
              {...editorBase}
              lines={lines}
              onAddFee={(feeId) => addFee.mutateAsync(feeId)}
            />
          )}
          <QuoteDetailsCard
            quote={quote}
            customer={customer.data}
            editable={editable}
            today={today}
          />
        </div>
        <div className="flex min-w-0 flex-col gap-4">
          <TotalsCard
            title={effectiveOption ? `Totals · ${effectiveOption.name}` : 'Totals'}
            currency={currency}
            subtotalCents={quote.subtotal_cents}
            discountCents={quote.discount_cents}
            taxCents={quote.tax_cents}
            taxRateBps={quote.tax_rate_bps}
            totalCents={quote.total_cents}
            footer={
              hasOptions || lines.some((l) => l.optional && !l.selected) ? (
                <div className="text-muted flex flex-col gap-1 text-xs">
                  {hasOptions && (
                    <p>
                      {quote.selected_option_id
                        ? 'Totals of the option the customer chose.'
                        : 'Totals of the first option until the customer chooses one. Each option’s total is listed with the options.'}
                    </p>
                  )}
                  {lines.some((l) => l.optional && !l.selected) && (
                    <p>Optional items are not included until the customer chooses them.</p>
                  )}
                </div>
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
          {canManage && (quote.status === 'sent' || quote.status === 'viewed') && (
            <FollowupStatusCard
              kind="quote"
              documentId={quote.id}
              timezone={timezone}
              noun="quote"
            />
          )}
          <QuoteTimeline quote={quote} timezone={timezone} />
        </div>
      </div>

      {customer.data && (
        <SendDocumentDialog
          open={pending === 'send'}
          onClose={() => setPending(null)}
          kind="quote"
          documentId={quote.id}
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
        options={options}
        defaultOptionId={quote.selected_option_id}
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
        description="This draft, its options and its line items are deleted permanently."
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
