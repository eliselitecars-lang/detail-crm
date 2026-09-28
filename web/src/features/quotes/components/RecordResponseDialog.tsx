import { useState } from 'react';
import {
  Button,
  Checkbox,
  Dialog,
  FormField,
  Input,
  RadioGroup,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useSetQuoteStatus, type QuoteOptionRow } from '../api';
import type { DocLine } from '../shared/lines';

export interface RecordResponseDialogProps {
  quoteId: string;
  /** Which customer response staff is recording; null = closed. */
  response: 'approved' | 'declined' | null;
  onClose: () => void;
  /** The quote's lines: optional ones get a "customer chose this" checkbox on approval. */
  lines: readonly DocLine[];
  currency: string;
  /** Proposal options: approving records which one the customer chose. */
  options?: readonly QuoteOptionRow[];
  /** Preselected option (the quote's current choice). */
  defaultOptionId?: string | null;
}

/** Staff record an approval/decline the customer gave in person or by phone. */
export function RecordResponseDialog({
  quoteId,
  response,
  onClose,
  lines,
  currency,
  options = [],
  defaultOptionId = null,
}: RecordResponseDialogProps) {
  const hasOptional = lines.some((line) => line.optional);
  const hasOptions = options.length > 0;
  return (
    <Dialog
      open={response !== null}
      onClose={onClose}
      title={response === 'declined' ? 'Mark quote as declined' : 'Mark quote as approved'}
      description={
        response === 'declined'
          ? 'Use this when the customer declined outside the online quote page.'
          : hasOptions
            ? 'Use this when the customer approved in person or by phone. Choose the option they picked; the other options are left off the job.'
            : hasOptional
              ? 'Use this when the customer approved in person or by phone. Tick the optional items they chose; unticked ones are left off the job.'
              : 'Use this when the customer approved in person or by phone.'
      }
      size="sm"
    >
      {response !== null && (
        <ResponseForm
          quoteId={quoteId}
          response={response}
          onClose={onClose}
          lines={lines}
          currency={currency}
          options={options}
          defaultOptionId={defaultOptionId}
        />
      )}
    </Dialog>
  );
}

function ResponseForm({
  quoteId,
  response,
  onClose,
  lines,
  currency,
  options,
  defaultOptionId,
}: {
  quoteId: string;
  response: 'approved' | 'declined';
  onClose: () => void;
  lines: readonly DocLine[];
  currency: string;
  options: readonly QuoteOptionRow[];
  defaultOptionId: string | null;
}) {
  const toast = useToast();
  const setStatus = useSetQuoteStatus(quoteId);
  const [text, setText] = useState('');
  const hasOptions = options.length > 0;
  const [optionId, setOptionId] = useState<string>(() =>
    defaultOptionId && options.some((o) => o.id === defaultOptionId) ? defaultOptionId : '',
  );
  const [optionError, setOptionError] = useState<string | null>(null);
  // Optional items the customer can pick: shared ones, plus those of the chosen option.
  const optionalLines =
    response === 'approved'
      ? lines.filter(
          (line) => line.optional && (line.option_id === null || line.option_id === optionId),
        )
      : [];
  const [chosen, setChosen] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(lines.filter((l) => l.optional).map((line) => [line.id, line.selected])),
  );
  const tooLong = response === 'approved' ? text.length > 200 : text.length > 1000;

  const submit = async () => {
    if (tooLong) return;
    if (response === 'approved' && hasOptions && !optionId) {
      setOptionError('Choose the option the customer approved.');
      return;
    }
    try {
      await setStatus.mutateAsync(
        response === 'approved'
          ? {
              status: 'approved',
              approvedByName: text.trim() || null,
              selectedOptionalLineIds: optionalLines
                .filter((line) => chosen[line.id] ?? line.selected)
                .map((line) => line.id),
              optionId: hasOptions ? optionId : null,
            }
          : { status: 'declined', declinedReason: text.trim() || null },
      );
      toast.success(response === 'approved' ? 'Quote marked approved' : 'Quote marked declined');
      onClose();
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
      {response === 'approved' && hasOptions && (
        <RadioGroup<string>
          label="Option the customer chose"
          value={optionId}
          onChange={(value) => {
            setOptionId(value);
            setOptionError(null);
          }}
          options={options.map((option) => ({
            value: option.id,
            label: option.name,
            description: formatCents(option.total_cents, { currency }),
          }))}
          {...(optionError ? { error: optionError } : {})}
        />
      )}
      {optionalLines.length > 0 && (
        <fieldset className="flex flex-col gap-2">
          <legend className="text-ink mb-1 text-sm font-medium">
            Optional items the customer chose
          </legend>
          {optionalLines.map((line) => (
            <Checkbox
              key={line.id}
              label={line.name}
              description={formatCents(line.total_cents, { currency })}
              checked={chosen[line.id] ?? line.selected}
              onChange={(event) => {
                const checked = event.target.checked;
                setChosen((prev) => ({ ...prev, [line.id]: checked }));
              }}
            />
          ))}
        </fieldset>
      )}
      {response === 'approved' ? (
        <FormField
          label="Approved by"
          help="Who approved it (optional)."
          error={tooLong ? 'Use 200 characters or fewer.' : undefined}
        >
          <Input
            value={text}
            onChange={(event) => setText(event.target.value)}
            autoComplete="off"
          />
        </FormField>
      ) : (
        <FormField
          label="Reason"
          help="Optional."
          error={tooLong ? 'Use 1,000 characters or fewer.' : undefined}
        >
          <Textarea rows={3} value={text} onChange={(event) => setText(event.target.value)} />
        </FormField>
      )}
      <div className="flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={setStatus.isPending}>
          Cancel
        </Button>
        <Button
          type="submit"
          variant={response === 'declined' ? 'danger' : 'primary'}
          loading={setStatus.isPending}
          disabled={tooLong}
        >
          {response === 'approved' ? 'Mark approved' : 'Mark declined'}
        </Button>
      </div>
    </form>
  );
}
