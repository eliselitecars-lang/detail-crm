import { useState } from 'react';
import { Button, Checkbox, Dialog, FormField, Input, Textarea, useToast } from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useSetQuoteStatus } from '../api';
import type { DocLine } from '../shared/lines';

export interface RecordResponseDialogProps {
  quoteId: string;
  /** Which customer response staff is recording; null = closed. */
  response: 'approved' | 'declined' | null;
  onClose: () => void;
  /** The quote's lines: optional ones get a "customer chose this" checkbox on approval. */
  lines: readonly DocLine[];
  currency: string;
}

/** Staff record an approval/decline the customer gave in person or by phone. */
export function RecordResponseDialog({
  quoteId,
  response,
  onClose,
  lines,
  currency,
}: RecordResponseDialogProps) {
  const hasOptional = lines.some((line) => line.optional);
  return (
    <Dialog
      open={response !== null}
      onClose={onClose}
      title={response === 'declined' ? 'Mark quote as declined' : 'Mark quote as approved'}
      description={
        response === 'declined'
          ? 'Use this when the customer declined outside the online quote page.'
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
}: {
  quoteId: string;
  response: 'approved' | 'declined';
  onClose: () => void;
  lines: readonly DocLine[];
  currency: string;
}) {
  const toast = useToast();
  const setStatus = useSetQuoteStatus(quoteId);
  const [text, setText] = useState('');
  const optionalLines = response === 'approved' ? lines.filter((line) => line.optional) : [];
  const [chosen, setChosen] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(optionalLines.map((line) => [line.id, line.selected])),
  );
  const tooLong = response === 'approved' ? text.length > 200 : text.length > 1000;

  const submit = async () => {
    if (tooLong) return;
    try {
      await setStatus.mutateAsync(
        response === 'approved'
          ? {
              status: 'approved',
              approvedByName: text.trim() || null,
              selectedOptionalLineIds: optionalLines
                .filter((line) => chosen[line.id] ?? line.selected)
                .map((line) => line.id),
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
