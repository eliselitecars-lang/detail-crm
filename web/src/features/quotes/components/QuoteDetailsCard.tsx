import { useState } from 'react';
import { Link } from 'react-router';
import { Button, DateInput, FormField, SectionCard, Textarea, useToast } from '@/components/ui';
import { formatLocalDate, isLocalDate } from '@/lib/dates';
import { formatPhone } from '@/lib/phone';
import { useUpdateQuote, type QuotePatch, type QuoteRow } from '../api';
import type { PickerCustomer } from '../shared/api';
import { VehicleSelect } from '../shared/CustomerPicker';
import { customerName } from '../shared/format';

const MAX_TEXT = 20000;

interface Draft {
  vehicleId: string | null;
  validUntil: string;
  notes: string;
  terms: string;
  internalNotes: string;
}

function draftOf(quote: QuoteRow): Draft {
  return {
    vehicleId: quote.vehicle_id,
    validUntil: quote.valid_until ?? '',
    notes: quote.notes ?? '',
    terms: quote.terms ?? '',
    internalNotes: quote.internal_notes ?? '',
  };
}

export interface QuoteDetailsCardProps {
  quote: QuoteRow;
  customer: PickerCustomer | undefined;
  /** Content editable (draft / sent / viewed). Internal notes are always editable. */
  editable: boolean;
  today: string;
}

export function QuoteDetailsCard({ quote, customer, editable, today }: QuoteDetailsCardProps) {
  const toast = useToast();
  const update = useUpdateQuote(quote.id);
  const [draft, setDraft] = useState<Draft>(() => draftOf(quote));
  const [syncedAt, setSyncedAt] = useState(quote.updated_at);
  if (syncedAt !== quote.updated_at) {
    setSyncedAt(quote.updated_at);
    setDraft(draftOf(quote));
  }

  const original = draftOf(quote);
  const dirty = JSON.stringify(original) !== JSON.stringify(draft);
  const validError =
    draft.validUntil === ''
      ? undefined
      : !isLocalDate(draft.validUntil)
        ? 'Enter a valid date.'
        : draft.validUntil !== original.validUntil && draft.validUntil < today
          ? 'Choose today or a later date.'
          : undefined;
  const tooLong =
    draft.notes.length > MAX_TEXT ||
    draft.terms.length > MAX_TEXT ||
    draft.internalNotes.length > MAX_TEXT;

  const save = async () => {
    if (validError || tooLong) return;
    const patch: QuotePatch = { internal_notes: draft.internalNotes.trim() || null };
    if (editable) {
      patch.vehicle_id = draft.vehicleId;
      patch.valid_until = draft.validUntil || null;
      patch.notes = draft.notes.trim() || null;
      patch.terms = draft.terms.trim() || null;
    }
    try {
      await update.mutateAsync(patch);
      toast.success('Quote saved');
    } catch (error) {
      toast.error(error);
    }
  };

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
            disabled={!dirty || Boolean(validError) || tooLong}
          >
            Save details
          </Button>
        </div>
      }
    >
      <div className="flex flex-col gap-4">
        <div>
          <p className="text-muted text-xs font-medium">Customer</p>
          <Link
            to={`/app/customers/${quote.customer_id}`}
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
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <FormField label="Vehicle" disabled={!editable}>
            <VehicleSelect
              customerId={quote.customer_id}
              value={draft.vehicleId}
              onChange={(vehicleId) => setDraft({ ...draft, vehicleId })}
              disabled={!editable}
            />
          </FormField>
          <FormField
            label="Valid until"
            disabled={!editable}
            error={validError}
            help={
              draft.validUntil
                ? `Through the end of ${formatLocalDate(draft.validUntil)} (shop time).`
                : 'No expiry.'
            }
          >
            <DateInput
              value={draft.validUntil}
              disabled={!editable}
              onChange={(event) => setDraft({ ...draft, validUntil: event.target.value })}
            />
          </FormField>
        </div>
        <FormField label="Notes for the customer" disabled={!editable}>
          <Textarea
            rows={3}
            value={draft.notes}
            disabled={!editable}
            onChange={(event) => setDraft({ ...draft, notes: event.target.value })}
          />
        </FormField>
        <FormField label="Terms" disabled={!editable}>
          <Textarea
            rows={3}
            value={draft.terms}
            disabled={!editable}
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
