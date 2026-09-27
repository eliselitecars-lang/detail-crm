import { useState } from 'react';
import { Link } from 'react-router';
import {
  Button,
  DateInput,
  FormField,
  KeyValueList,
  SectionCard,
  Textarea,
  useToast,
} from '@/components/ui';
import {
  formatDate,
  formatLocalDate,
  isLocalDate,
  shopLocalToUtcIso,
  utcToShopLocal,
} from '@/lib/dates';
import { formatPhone } from '@/lib/phone';
import type { PickerCustomer } from '@/features/quotes/shared/api';
import { customerName } from '@/features/quotes/shared/format';
import { useUpdateInvoice, type InvoicePatch, type InvoiceRow } from '../api';

const MAX_TEXT = 20000;

interface Draft {
  dueDate: string;
  notes: string;
  terms: string;
  internalNotes: string;
}

function draftOf(invoice: InvoiceRow, timezone: string): Draft {
  return {
    dueDate: invoice.due_at ? utcToShopLocal(invoice.due_at, timezone).date : '',
    notes: invoice.notes ?? '',
    terms: invoice.terms ?? '',
    internalNotes: invoice.internal_notes ?? '',
  };
}

export interface InvoiceDetailsCardProps {
  invoice: InvoiceRow;
  customer: PickerCustomer | undefined;
  timezone: string;
  today: string;
  /** manager+ on a non-void invoice */
  editable: boolean;
}

export function InvoiceDetailsCard({
  invoice,
  customer,
  timezone,
  today,
  editable,
}: InvoiceDetailsCardProps) {
  const toast = useToast();
  const update = useUpdateInvoice(invoice.id);
  const [draft, setDraft] = useState<Draft>(() => draftOf(invoice, timezone));
  const [syncedAt, setSyncedAt] = useState(invoice.updated_at);
  if (syncedAt !== invoice.updated_at) {
    setSyncedAt(invoice.updated_at);
    setDraft(draftOf(invoice, timezone));
  }
  const original = draftOf(invoice, timezone);
  const dirty = JSON.stringify(original) !== JSON.stringify(draft);
  const dueChanged = draft.dueDate !== original.dueDate;
  // Once issued, an empty due date is not "no due date": invoices_compute
  // puts it back to issue time + the shop's default terms (often 0 days),
  // which is already past and flips the invoice to Overdue. Only drafts may
  // leave it empty (the default is applied when the invoice is sent).
  const issued = invoice.status !== 'draft';
  const dueError = !dueChanged
    ? undefined
    : draft.dueDate === ''
      ? issued
        ? 'An issued invoice needs a due date.'
        : undefined
      : !isLocalDate(draft.dueDate)
        ? 'Enter a valid date.'
        : draft.dueDate < today
          ? 'Choose today or a later date.'
          : undefined;
  const tooLong =
    draft.notes.length > MAX_TEXT ||
    draft.terms.length > MAX_TEXT ||
    draft.internalNotes.length > MAX_TEXT;

  const save = async () => {
    if (dueError || tooLong) return;
    const patch: InvoicePatch = {
      notes: draft.notes.trim() || null,
      terms: draft.terms.trim() || null,
      internal_notes: draft.internalNotes.trim() || null,
    };
    if (dueChanged) {
      // Due through the end of the chosen shop-local day.
      patch.due_at = draft.dueDate ? shopLocalToUtcIso(draft.dueDate, '23:59:59', timezone) : null;
    }
    try {
      await update.mutateAsync(patch);
      toast.success('Invoice saved');
    } catch (error) {
      toast.error(error);
    }
  };

  const customerBlock = (
    <div>
      <p className="text-muted text-xs font-medium">Customer</p>
      <Link
        to={`/app/customers/${invoice.customer_id}`}
        className="text-ink hover:text-primary-ink text-sm font-medium hover:underline"
      >
        {customerName(customer)}
      </Link>
      {customer && (
        <p className="text-muted text-xs break-words">
          {[customer.email, customer.phone ? formatPhone(customer.phone) : null]
            .filter(Boolean)
            .join(' · ') || 'No contact details'}
        </p>
      )}
    </div>
  );

  const facts = (
    <KeyValueList
      items={[
        {
          key: 'issued',
          label: 'Issued',
          value: invoice.issued_at ? formatDate(invoice.issued_at, timezone) : 'Not issued',
        },
        {
          key: 'sent',
          label: 'Last sent',
          value: invoice.sent_at ? formatDate(invoice.sent_at, timezone) : 'Never',
        },
        ...(invoice.paid_at
          ? [{ key: 'paid', label: 'Paid', value: formatDate(invoice.paid_at, timezone) }]
          : []),
        ...(invoice.voided_at
          ? [
              { key: 'voided', label: 'Voided', value: formatDate(invoice.voided_at, timezone) },
              { key: 'reason', label: 'Void reason', value: invoice.void_reason },
            ]
          : []),
        ...(invoice.job_id
          ? [
              {
                key: 'job',
                label: 'Job',
                value: (
                  <Link
                    to={`/app/jobs/${invoice.job_id}`}
                    className="text-primary-ink hover:underline"
                  >
                    View job
                  </Link>
                ),
              },
            ]
          : []),
      ]}
    />
  );

  if (!editable) {
    return (
      <SectionCard title="Details">
        <div className="flex flex-col gap-4">
          {customerBlock}
          <KeyValueList
            items={[
              {
                key: 'due',
                label: 'Due',
                value: original.dueDate ? formatLocalDate(original.dueDate) : 'No due date',
              },
            ]}
          />
          {facts}
          {invoice.notes && (
            <div>
              <p className="text-muted text-xs font-medium">Notes</p>
              <p className="text-ink text-sm whitespace-pre-line">{invoice.notes}</p>
            </div>
          )}
        </div>
      </SectionCard>
    );
  }

  return (
    <SectionCard
      title="Details"
      footer={
        <div className="flex justify-end gap-2">
          <Button
            variant="ghost"
            size="sm"
            disabled={!dirty || update.isPending}
            onClick={() => setDraft(original)}
          >
            Discard
          </Button>
          <Button
            size="sm"
            onClick={() => void save()}
            loading={update.isPending}
            disabled={!dirty || Boolean(dueError) || tooLong}
          >
            Save details
          </Button>
        </div>
      }
    >
      <div className="flex flex-col gap-4">
        {customerBlock}
        <FormField
          label="Due date"
          error={dueError}
          required={issued}
          help={
            !issued && !draft.dueDate
              ? 'Leave empty to use your shop’s default payment terms when it’s sent.'
              : 'Due through the end of this day (shop time).'
          }
        >
          <DateInput
            value={draft.dueDate}
            onChange={(event) => setDraft({ ...draft, dueDate: event.target.value })}
          />
        </FormField>
        {facts}
        <FormField label="Notes for the customer">
          <Textarea
            rows={3}
            value={draft.notes}
            onChange={(event) => setDraft({ ...draft, notes: event.target.value })}
          />
        </FormField>
        <FormField label="Terms">
          <Textarea
            rows={3}
            value={draft.terms}
            onChange={(event) => setDraft({ ...draft, terms: event.target.value })}
          />
        </FormField>
        <FormField label="Internal notes" help="Only your team sees these.">
          <Textarea
            rows={2}
            value={draft.internalNotes}
            onChange={(event) => setDraft({ ...draft, internalNotes: event.target.value })}
          />
        </FormField>
        {tooLong && (
          <p role="alert" className="text-danger-ink text-sm">
            Notes and terms are limited to 20,000 characters.
          </p>
        )}
      </div>
    </SectionCard>
  );
}
