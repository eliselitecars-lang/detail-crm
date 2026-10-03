import { CircleX, FileCheck2, FileDown, Printer } from 'lucide-react';
import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useParams, useSearchParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Badge,
  Button,
  buttonClasses,
  Card,
  Checkbox,
  Dialog,
  FormField,
  Input,
  SectionCard,
  StatusBadge,
  Textarea,
  useToast,
} from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatDate, formatDateTime, formatLocalDate } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { publicPdfUrl } from '@/features/quotes/shared/pdf';
import {
  PAID_POLL_ATTEMPTS,
  useCancelQuoteDepositCheckout,
  usePublicQuote,
  useRespondQuote,
  type QuoteDocument,
  type QuoteLine,
  type QuoteOption,
} from './api';
import { QuoteSchedulePanel, QuoteScheduledPanel } from './components/QuoteSchedule';
import { LineList, LineRow, TotalsList } from './shared/DocumentLines';
import { personName } from './shared/format';
import { Banner, DocumentTitle, PublicError, PublicLoading } from './shared/PublicPage';
import { isLinkToken, toBranding, vehicleLabel } from './shared/schemas';
import { standardTotals } from './shared/totals';

export default function QuotePage() {
  const { token } = useParams();
  if (!isLinkToken(token)) return <PublicError error={null} what="quote" />;
  return <QuoteView token={token} />;
}

function QuoteView({ token }: { token: string }) {
  const [params] = useSearchParams();
  const paidReturn = params.get('paid') === '1';
  const canceledReturn = params.get('canceled') === '1';
  const { query, loads } = usePublicQuote(token, { pollForDeposit: paidReturn });
  if (query.isPending) return <PublicLoading label="Loading quote…" />;
  if (query.isError) {
    return (
      <PublicError
        error={query.error}
        what="quote"
        onRetry={() => void query.refetch()}
        retrying={query.isFetching}
      />
    );
  }
  const schedule = query.data.self_schedule;
  const depositSettled = !schedule.payment_pending && (schedule.deposit_due_cents ?? 0) <= 0;
  return (
    <QuoteDocumentView
      token={token}
      doc={query.data}
      paidReturn={paidReturn}
      pollingDone={depositSettled || loads >= PAID_POLL_ATTEMPTS}
      canceledReturn={canceledReturn}
      refreshing={query.isFetching}
      onRefresh={() => void query.refetch()}
    />
  );
}

/**
 * Back from Stripe with ?canceled=1: the customer left the deposit page of
 * the job they scheduled here, yet it stays payable (and holds the booking)
 * until Stripe expires it ~30-40 minutes later. Close it once, quietly, by
 * the job's booking token (self_schedule.job_token); if that fails, the page
 * still expires on its own.
 */
function useCloseAbandonedDeposit(token: string, jobToken: string | null, active: boolean) {
  const { mutate } = useCancelQuoteDepositCheckout(token);
  const done = useRef(false);
  useEffect(() => {
    if (!active || !jobToken || done.current) return;
    done.current = true;
    mutate(jobToken);
  }, [active, jobToken, mutate]);
}

/**
 * The line under the totals about optional add-ons. The total shown is the
 * server's: it counts the add-ons the shop pre-selected (`selected`), so it
 * says it includes add-ons only when one is; while the customer's ticks
 * differ, it says those are priced on approval. Null when there is nothing
 * true to say (no add-ons, or none included and none ticked).
 */
function optionalAddOnsNote(
  optional: readonly QuoteLine[],
  picked: ReadonlySet<string>,
  canRespond: boolean,
): string | null {
  const included = optional.some((l) => l.selected);
  const changed = optional.some((l) => l.selected !== picked.has(l.id));
  if (changed && canRespond) {
    return included
      ? 'This total reflects the add-ons that were pre-selected. Your changes are priced by the shop when you approve.'
      : 'This total doesn’t include add-ons yet. The ones you choose are priced by the shop when you approve.';
  }
  return included ? 'Total includes the selected optional add-ons.' : null;
}

/** Lines of one option (or the shared ones, optionId null), split into required / optional. */
function linesOf(lines: readonly QuoteLine[], optionId: string | null) {
  const own = lines.filter((l) => l.option_id === optionId);
  return { required: own.filter((l) => !l.optional), optional: own.filter((l) => l.optional) };
}

function QuoteDocumentView({
  token,
  doc,
  paidReturn,
  pollingDone,
  canceledReturn,
  refreshing,
  onRefresh,
}: {
  token: string;
  doc: QuoteDocument;
  paidReturn: boolean;
  /** Back from Stripe: the deposit settled, or the page stopped re-checking. */
  pollingDone: boolean;
  canceledReturn: boolean;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  const { shop, quote, options } = doc;
  const currency = shop.currency;
  const tz = shop.timezone;
  const hasOptions = quote.has_options && options.length > 0;
  const canRespond = quote.can_respond;
  // The server's selected_option_id falls back to the first option (0067
  // quote_effective_option), so it is the customer's choice only once the
  // quote was accepted; a declined or expired quote has no choice to show.
  const acceptedOption =
    hasOptions && (quote.status === 'approved' || quote.status === 'converted')
      ? quote.selected_option_id
      : null;
  const [chosenOption, setChosenOption] = useState<string | null>(() =>
    // An accepted quote shows the customer's choice; an open one starts unchosen.
    canRespond ? null : acceptedOption,
  );
  const [picked, setPicked] = useState<ReadonlySet<string>>(
    () => new Set(doc.line_items.filter((l) => l.optional && l.selected).map((l) => l.id)),
  );
  const customer = personName(doc.customer);
  const vehicle = vehicleLabel(doc.vehicle);
  const shared = linesOf(doc.line_items, null);
  // Optional add-ons on offer: shared ones plus those of the chosen option.
  const optional = hasOptions
    ? [...shared.optional, ...(chosenOption ? linesOf(doc.line_items, chosenOption).optional : [])]
    : shared.optional;
  const addOnsNote = optionalAddOnsNote(optional, picked, canRespond);
  const totalsOption = hasOptions ? (options.find((o) => o.id === chosenOption) ?? null) : null;
  const totals = totalsOption ?? quote;
  const pdfUrl = publicPdfUrl('quote', token);
  const schedule = doc.self_schedule;
  useCloseAbandonedDeposit(token, schedule.job_token, canceledReturn && !paidReturn);

  const toggle = (id: string, on: boolean) =>
    setPicked((prev) => {
      const next = new Set(prev);
      if (on) next.add(id);
      else next.delete(id);
      return next;
    });

  return (
    <PublicLayout shop={toBranding(shop)} title={`Quote #${quote.number}`}>
      {/* Printable: actions/banners are print:hidden; every option prints. */}
      <div className="flex flex-col gap-4 sm:gap-5 print:gap-3 print:text-black print:[&_*]:shadow-none print:[&>*]:break-inside-avoid">
        <DocumentTitle
          title={`Quote #${quote.number}`}
          badge={<StatusBadge kind="quote" status={quote.status} />}
          subtitle={[
            customer ? `Prepared for ${customer}` : null,
            vehicle,
            quote.sent_at ? `Sent ${formatDate(quote.sent_at, tz)}` : null,
          ]
            .filter(Boolean)
            .join(' · ')}
          actions={
            <>
              <Button
                variant="secondary"
                leadingIcon={<Printer className="size-4" aria-hidden="true" />}
                onClick={() => window.print()}
              >
                Print
              </Button>
              {pdfUrl && (
                <a
                  href={pdfUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  className={buttonClasses({ variant: 'secondary' })}
                >
                  <FileDown className="size-4" aria-hidden="true" />
                  Download PDF
                </a>
              )}
            </>
          }
        />

        <QuoteStateBanner doc={doc} />

        {hasOptions ? (
          <>
            {(shared.required.length > 0 || !canRespond) && (
              <SectionCard title="Included in every option" flush>
                <div className="px-4 sm:px-5">
                  <LineList
                    lines={shared.required}
                    currency={currency}
                    label="Included in every option"
                  />
                </div>
              </SectionCard>
            )}
            <OptionCards
              doc={doc}
              chosen={chosenOption}
              answeredChoice={canRespond ? null : acceptedOption}
              onChoose={canRespond ? setChosenOption : null}
            />
          </>
        ) : (
          <SectionCard title="Quote items" flush>
            <div className="px-4 sm:px-5">
              <LineList lines={shared.required} currency={currency} label="Quote items" />
            </div>
          </SectionCard>
        )}

        {optional.length > 0 && (
          <SectionCard
            title="Optional add-ons"
            description={
              canRespond
                ? 'Choose any extras you’d like. Your final total is calculated when you approve.'
                : 'Extras offered with this quote.'
            }
            flush
          >
            <ul aria-label="Optional add-ons" className="divide-line divide-y px-4 sm:px-5">
              {optional.map((line) => (
                <OptionalLine
                  key={line.id}
                  line={line}
                  currency={currency}
                  checked={picked.has(line.id)}
                  editable={canRespond}
                  onChange={(on) => toggle(line.id, on)}
                />
              ))}
            </ul>
          </SectionCard>
        )}

        <Card padded>
          {totalsOption && (
            <p className="text-muted mb-2 text-xs font-medium">{totalsOption.name}</p>
          )}
          {hasOptions && !totalsOption ? (
            <p className="text-muted text-sm">
              {canRespond
                ? 'Choose an option above to see its total. Each option’s total is shown on its card.'
                : 'Each option’s total is shown on its card.'}
            </p>
          ) : (
            <TotalsList
              currency={currency}
              rows={standardTotals({ ...totals, tax_rate_bps: quote.tax_rate_bps })}
            />
          )}
          {addOnsNote && <p className="text-muted mt-3 text-xs">{addOnsNote}</p>}
          {quote.valid_until && (
            <p className="text-muted mt-2 text-xs">
              Valid until {formatLocalDate(quote.valid_until)}
            </p>
          )}
        </Card>

        {(quote.notes || quote.terms) && (
          <SectionCard title="Notes & terms">
            <div className="text-ink flex flex-col gap-3 text-sm break-words whitespace-pre-line">
              {quote.notes && <p>{quote.notes}</p>}
              {quote.terms && <p className="text-muted">{quote.terms}</p>}
            </div>
          </SectionCard>
        )}

        {canRespond && (
          <RespondPanel
            token={token}
            picked={picked}
            optional={optional}
            hasOptions={hasOptions}
            chosenOption={hasOptions ? (options.find((o) => o.id === chosenOption) ?? null) : null}
          />
        )}

        {quote.status === 'approved' && schedule.available && (
          <QuoteSchedulePanel token={token} doc={doc} />
        )}
        {schedule.job_token && (
          <QuoteScheduledPanel
            token={token}
            doc={doc}
            paidReturn={paidReturn}
            pollingDone={pollingDone}
            canceledReturn={canceledReturn}
            refreshing={refreshing}
            onRefresh={onRefresh}
          />
        )}
      </div>
    </PublicLayout>
  );
}

/** Side-by-side option cards (stacked on phones), each with its own lines and total. */
function OptionCards({
  doc,
  chosen,
  answeredChoice,
  onChoose,
}: {
  doc: QuoteDocument;
  chosen: string | null;
  /** The option the customer accepted (approved / converted quotes only). */
  answeredChoice: string | null;
  /** null = read-only (the quote can no longer be answered). */
  onChoose: ((id: string) => void) | null;
}) {
  const { options, shop } = doc;
  const currency = shop.currency;
  return (
    <section aria-label="Options">
      <h2 className="text-ink mb-2 text-base font-semibold">
        {onChoose ? 'Choose an option' : 'Options'}
      </h2>
      <div
        className={cn(
          'grid grid-cols-1 gap-3',
          options.length === 2 && 'md:grid-cols-2',
          options.length >= 3 && 'md:grid-cols-3',
          options.length === 4 && 'md:grid-cols-2 lg:grid-cols-4',
        )}
      >
        {options.map((option) => (
          <OptionCard
            key={option.id}
            option={option}
            lines={linesOf(doc.line_items, option.id).required}
            currency={currency}
            selected={chosen === option.id}
            answeredChoice={answeredChoice === option.id}
            answered={answeredChoice !== null}
            onChoose={onChoose}
          />
        ))}
      </div>
    </section>
  );
}

function OptionCard({
  option,
  lines,
  currency,
  selected,
  answeredChoice,
  answered,
  onChoose,
}: {
  option: QuoteOption;
  lines: QuoteLine[];
  currency: string;
  selected: boolean;
  answeredChoice: boolean;
  answered: boolean;
  onChoose: ((id: string) => void) | null;
}) {
  const active = selected || answeredChoice;
  return (
    <Card
      padded
      className={cn(
        'flex flex-col gap-3 transition-shadow',
        active && 'ring-brand ring-2',
        answered && !answeredChoice && 'opacity-70 print:opacity-100',
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <h3 className="text-ink text-sm font-semibold break-words">{option.name}</h3>
        {answeredChoice && <Badge tone="success">Your choice</Badge>}
      </div>
      {option.description && (
        <p className="text-muted text-xs break-words whitespace-pre-line">{option.description}</p>
      )}
      {lines.length > 0 && (
        <ul aria-label={`${option.name} items`} className="divide-line divide-y">
          {lines.map((line) => (
            <LineRow key={line.id} line={line} currency={currency} />
          ))}
        </ul>
      )}
      <div className="mt-auto flex items-end justify-between gap-2 pt-1">
        <div>
          <p className="text-muted text-xs">Total</p>
          <p className="text-ink text-lg font-semibold tabular-nums">
            {formatCents(option.total_cents, { currency })}
          </p>
        </div>
        {onChoose && (
          <Button
            size="sm"
            variant={selected ? 'primary' : 'secondary'}
            aria-pressed={selected}
            aria-label={`${selected ? 'Chosen' : 'Choose'} ${option.name}`}
            className="print:hidden"
            onClick={() => onChoose(option.id)}
          >
            {selected ? 'Chosen' : 'Choose'}
          </Button>
        )}
      </div>
    </Card>
  );
}

function OptionalLine({
  line,
  currency,
  checked,
  editable,
  onChange,
}: {
  line: QuoteLine;
  currency: string;
  checked: boolean;
  editable: boolean;
  onChange: (on: boolean) => void;
}) {
  if (!editable) {
    return (
      <LineRow
        line={line}
        currency={currency}
        trailingNote={
          <p className="text-muted mt-0.5 text-xs">{line.selected ? 'Included' : 'Not included'}</p>
        }
      />
    );
  }
  const details = [line.description, line.vehicle_label].filter(Boolean).join(' · ');
  return (
    <li className="flex items-start gap-3 py-3">
      <Checkbox
        className="min-w-0 flex-1"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        label={<span className="font-medium">{line.name}</span>}
        {...(details ? { description: details } : {})}
      />
      <p className="text-ink shrink-0 text-sm font-medium tabular-nums">
        +{formatCents(line.total_cents, { currency })}
      </p>
    </li>
  );
}

function QuoteStateBanner({ doc }: { doc: QuoteDocument }) {
  const { quote, shop, self_schedule: schedule } = doc;
  const tz = shop.timezone;
  switch (quote.status) {
    case 'approved':
      return (
        <Banner tone="success" title="Quote approved">
          {quote.approved_by_name ? `Approved by ${quote.approved_by_name}` : 'Approved'}
          {quote.approved_at ? ` on ${formatDateTime(quote.approved_at, tz)}` : ''}.{' '}
          {schedule.available
            ? 'Pick a time for the work below.'
            : `${shop.name} will be in touch to schedule the work.`}
        </Banner>
      );
    case 'converted':
      if (schedule.job_token) return null; // the booked panel says it
      return (
        <Banner tone="success" title="Quote accepted and scheduled">
          This quote has been turned into an appointment. {shop.name} will send you the details.
        </Banner>
      );
    case 'declined':
      return (
        <Banner tone="info" title="Quote declined">
          {quote.declined_at ? `Declined on ${formatDate(quote.declined_at, tz)}.` : 'Declined.'}
          {quote.declined_reason ? ` Reason: ${quote.declined_reason}` : ''}
        </Banner>
      );
    case 'expired':
      return (
        <Banner tone="warning" title="This quote has expired">
          Contact {shop.name} for an updated quote.
        </Banner>
      );
    default:
      if (!quote.can_respond) {
        return (
          <Banner tone="warning" title="This quote can no longer be answered online">
            Contact {shop.name} for an updated quote.
          </Banner>
        );
      }
      return null;
  }
}

function RespondPanel({
  token,
  picked,
  optional,
  hasOptions,
  chosenOption,
}: {
  token: string;
  picked: ReadonlySet<string>;
  optional: QuoteLine[];
  hasOptions: boolean;
  chosenOption: QuoteOption | null;
}) {
  const toast = useToast();
  const respond = useRespondQuote(token);
  const [name, setName] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const [optionError, setOptionError] = useState<string | null>(null);
  const [declineOpen, setDeclineOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [reasonError, setReasonError] = useState<string | null>(null);

  const approve = (event: FormEvent) => {
    event.preventDefault();
    const signer = name.trim();
    if (hasOptions && !chosenOption) {
      setOptionError('Choose one of the options above first.');
      return;
    }
    setOptionError(null);
    if (!signer) {
      setNameError('Type your full name to approve.');
      return;
    }
    if (signer.length > 200) {
      setNameError('Name must be 200 characters or fewer.');
      return;
    }
    setNameError(null);
    respond.mutate(
      {
        action: 'approve',
        signerName: signer,
        selectedOptionalIds: optional.filter((l) => picked.has(l.id)).map((l) => l.id),
        optionId: chosenOption?.id ?? null,
      },
      { onSuccess: () => toast.success('Quote approved — thank you!') },
    );
  };

  const decline = () => {
    if (reason.trim().length > 1000) {
      setReasonError('Reason must be 1000 characters or fewer.');
      return;
    }
    setReasonError(null);
    respond.mutate(
      { action: 'decline', reason },
      {
        onSuccess: () => {
          setDeclineOpen(false);
          toast.success('Thanks for letting us know.');
        },
      },
    );
  };

  const pending = respond.isPending;
  const approving = pending && respond.variables.action === 'approve';
  const declining = pending && respond.variables.action === 'decline';
  const addOns = optional.filter((l) => picked.has(l.id)).length;

  return (
    <SectionCard
      title="Approve this quote"
      description="Typing your full name below acts as your signature."
      className="print:hidden"
    >
      <form noValidate onSubmit={approve} className="flex flex-col gap-4">
        {respond.isError && !declineOpen && (
          <Banner tone="danger" title="Couldn’t send your response">
            {errorMessage(respond.error)}
          </Banner>
        )}
        {hasOptions && (
          <p className={cn('text-sm', optionError ? 'text-danger-ink' : 'text-ink')} role="status">
            {optionError ??
              (chosenOption
                ? `You chose ${chosenOption.name}.`
                : 'Choose one of the options above before approving.')}
          </p>
        )}
        <FormField label="Your full name" required error={nameError}>
          <Input
            value={name}
            onChange={(event) => setName(event.target.value)}
            autoComplete="name"
            maxLength={200}
            inputSize="lg"
          />
        </FormField>
        <p className="text-muted text-xs">
          By approving, you accept this quote
          {chosenOption ? ` (${chosenOption.name})` : ''}
          {addOns > 0 ? ` with ${addOns} optional add-on${addOns === 1 ? '' : 's'}` : ''} and its
          terms.
        </p>
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button
            variant="secondary"
            size="lg"
            leadingIcon={<CircleX className="size-4" aria-hidden="true" />}
            onClick={() => {
              respond.reset();
              setDeclineOpen(true);
            }}
            disabled={pending}
          >
            Decline
          </Button>
          <Button
            type="submit"
            size="lg"
            loading={approving}
            disabled={pending}
            leadingIcon={<FileCheck2 className="size-4" aria-hidden="true" />}
          >
            Approve quote
          </Button>
        </div>
      </form>
      <Dialog
        open={declineOpen}
        onClose={() => setDeclineOpen(false)}
        title="Decline this quote?"
        description="Let the shop know why (optional)."
        dismissible={!declining}
        footer={
          <>
            <Button variant="secondary" onClick={() => setDeclineOpen(false)} disabled={declining}>
              Keep quote
            </Button>
            <Button variant="danger" loading={declining} onClick={decline}>
              Decline quote
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-3">
          {respond.isError && declineOpen && (
            <Banner tone="danger" title="Couldn’t decline">
              {errorMessage(respond.error)}
            </Banner>
          )}
          <FormField label="Reason" error={reasonError}>
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
