import { CircleX, FileCheck2 } from 'lucide-react';
import { useState, type FormEvent } from 'react';
import { useParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Button,
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
import { formatDate, formatDateTime, formatLocalDate } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { usePublicQuote, useRespondQuote, type QuoteDocument, type QuoteLine } from './api';
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
  const query = usePublicQuote(token);
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
  return <QuoteDocumentView token={token} doc={query.data} />;
}

function QuoteDocumentView({ token, doc }: { token: string; doc: QuoteDocument }) {
  const { shop, quote } = doc;
  const currency = shop.currency;
  const tz = shop.timezone;
  const required = doc.line_items.filter((l) => !l.optional);
  const optional = doc.line_items.filter((l) => l.optional);
  const [picked, setPicked] = useState<ReadonlySet<string>>(
    () => new Set(optional.filter((l) => l.selected).map((l) => l.id)),
  );
  const customer = personName(doc.customer);
  const vehicle = vehicleLabel(doc.vehicle);
  const canRespond = quote.can_respond;
  const selectionChanged = optional.some((l) => l.selected !== picked.has(l.id));

  const toggle = (id: string, on: boolean) =>
    setPicked((prev) => {
      const next = new Set(prev);
      if (on) next.add(id);
      else next.delete(id);
      return next;
    });

  return (
    <PublicLayout shop={toBranding(shop)}>
      <div className="flex flex-col gap-4 sm:gap-5">
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
        />

        <QuoteStateBanner doc={doc} />

        <SectionCard title="Quote items" flush>
          <div className="px-4 sm:px-5">
            <LineList lines={required} currency={currency} label="Quote items" />
          </div>
        </SectionCard>

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
          <TotalsList currency={currency} rows={standardTotals(quote)} />
          {optional.length > 0 && (
            <p className="text-muted mt-3 text-xs">
              {selectionChanged && canRespond
                ? 'This total reflects the add-ons that were pre-selected. Your changes are priced by the shop when you approve.'
                : 'Total includes the selected optional add-ons.'}
            </p>
          )}
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

        {canRespond && <RespondPanel token={token} picked={picked} optional={optional} />}
      </div>
    </PublicLayout>
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
  const { quote, shop } = doc;
  const tz = shop.timezone;
  switch (quote.status) {
    case 'approved':
      return (
        <Banner tone="success" title="Quote approved">
          {quote.approved_by_name ? `Approved by ${quote.approved_by_name}` : 'Approved'}
          {quote.approved_at ? ` on ${formatDateTime(quote.approved_at, tz)}` : ''}. {shop.name}{' '}
          will be in touch to schedule the work.
        </Banner>
      );
    case 'converted':
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
}: {
  token: string;
  picked: ReadonlySet<string>;
  optional: QuoteLine[];
}) {
  const toast = useToast();
  const respond = useRespondQuote(token);
  const [name, setName] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const [declineOpen, setDeclineOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [reasonError, setReasonError] = useState<string | null>(null);

  const approve = (event: FormEvent) => {
    event.preventDefault();
    const signer = name.trim();
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
    >
      <form noValidate onSubmit={approve} className="flex flex-col gap-4">
        {respond.isError && !declineOpen && (
          <Banner tone="danger" title="Couldn’t send your response">
            {errorMessage(respond.error)}
          </Banner>
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
