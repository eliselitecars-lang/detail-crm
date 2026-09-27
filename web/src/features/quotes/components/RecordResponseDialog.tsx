import { useState } from 'react';
import { Button, Dialog, FormField, Input, Textarea, useToast } from '@/components/ui';
import { useSetQuoteStatus } from '../api';

export interface RecordResponseDialogProps {
  quoteId: string;
  /** Which customer response staff is recording; null = closed. */
  response: 'approved' | 'declined' | null;
  onClose: () => void;
}

/** Staff record an approval/decline the customer gave in person or by phone. */
export function RecordResponseDialog({ quoteId, response, onClose }: RecordResponseDialogProps) {
  return (
    <Dialog
      open={response !== null}
      onClose={onClose}
      title={response === 'declined' ? 'Mark quote as declined' : 'Mark quote as approved'}
      description={
        response === 'declined'
          ? 'Use this when the customer declined outside the online quote page.'
          : 'Use this when the customer approved in person or by phone. Optional items the customer did not choose stay unselected.'
      }
      size="sm"
    >
      {response !== null && (
        <ResponseForm quoteId={quoteId} response={response} onClose={onClose} />
      )}
    </Dialog>
  );
}

function ResponseForm({
  quoteId,
  response,
  onClose,
}: {
  quoteId: string;
  response: 'approved' | 'declined';
  onClose: () => void;
}) {
  const toast = useToast();
  const setStatus = useSetQuoteStatus(quoteId);
  const [text, setText] = useState('');
  const tooLong = response === 'approved' ? text.length > 200 : text.length > 1000;

  const submit = async () => {
    if (tooLong) return;
    try {
      await setStatus.mutateAsync(
        response === 'approved'
          ? { status: 'approved', approvedByName: text.trim() || null }
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
