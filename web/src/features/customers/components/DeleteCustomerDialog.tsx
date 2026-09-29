import { CircleAlert, Info } from 'lucide-react';
import { useRef } from 'react';
import { useNavigate } from 'react-router';
import { Button, Dialog, ErrorState, LoadingState, useToast } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { AppError } from '@/lib/errors';
import { useCustomerErasePreview, useDeleteCustomer } from '../api';
import {
  eraseBlocked,
  eraseErrorMessage,
  eraseNotes,
  eraseToast,
  type ErasePreview,
} from '../erase';

export interface DeleteCustomerDialogProps {
  onClose: () => void;
  customer: { id: string; name: string };
}

/**
 * Owner / admin: a customer's deletion request (payments → erase_customer).
 * Mount it only while open: each opening asks the server for a fresh dry run,
 * which says whether the record will be deleted or anonymised (money rows
 * reference it) and what is in the way. Confirming runs it for real, then
 * returns to the customer list.
 */
export function DeleteCustomerDialog({ onClose, customer }: DeleteCustomerDialogProps) {
  const { shopId } = useShop();
  const toast = useToast();
  const navigate = useNavigate();
  const preview = useCustomerErasePreview(shopId, customer.id);
  const erase = useDeleteCustomer(shopId);
  const cancelRef = useRef<HTMLButtonElement>(null);

  const data = preview.data;
  const anonymise = data?.mode === 'anonymised';
  const blocked = data ? eraseBlocked(data) : true;

  const close = () => {
    if (erase.isPending) return;
    onClose();
  };

  const confirm = async () => {
    if (!data || blocked || erase.isPending) return;
    try {
      const result = await erase.mutateAsync(customer.id);
      const message = eraseToast(customer.name, result);
      toast.success(message.title, message.description);
      onClose();
      await navigate('/app/customers', { replace: true });
    } catch {
      // Shown inline (erase.error); the blockers may have changed meanwhile.
      void preview.refetch();
    }
  };

  return (
    <Dialog
      open
      onClose={close}
      role="alertdialog"
      size="md"
      title={anonymise ? `Anonymise ${customer.name}?` : `Delete ${customer.name}?`}
      description={data ? modeDescription(data) : undefined}
      dismissible={!erase.isPending}
      initialFocus={cancelRef}
      footer={
        <>
          <Button ref={cancelRef} variant="secondary" onClick={close} disabled={erase.isPending}>
            Cancel
          </Button>
          <Button
            variant="danger"
            disabled={!data || blocked}
            loading={erase.isPending}
            onClick={() => void confirm()}
          >
            {anonymise ? 'Anonymise customer' : 'Delete customer'}
          </Button>
        </>
      }
    >
      {preview.isPending ? (
        <LoadingState label="Checking what deleting this customer involves…" />
      ) : preview.isError ? (
        <ErrorState
          compact
          title="Couldn’t check this customer"
          error={new AppError(eraseErrorMessage(preview.error), { cause: preview.error })}
          onRetry={() => void preview.refetch()}
          retrying={preview.isRefetching}
        />
      ) : (
        <PreviewBody preview={preview.data} />
      )}
      {erase.isError && (
        <p
          role="alert"
          className="bg-danger-soft text-danger-ink rounded-control mt-4 px-3 py-2 text-sm"
        >
          {eraseErrorMessage(erase.error)}
        </p>
      )}
    </Dialog>
  );
}

function modeDescription(preview: ErasePreview): string {
  if (preview.erased) {
    return 'This customer’s personal details were already removed at their request.';
  }
  return preview.mode === 'deleted'
    ? 'They have no jobs, invoices, payments or memberships, so the customer is deleted for good. This can’t be undone.'
    : 'They have jobs, invoices, payments or a membership on file, so instead of being deleted the customer is anonymised: those records are kept for your books without their personal details. This can’t be undone.';
}

function PreviewBody({ preview }: { preview: ErasePreview }) {
  const notes = eraseNotes(preview);
  const blockers = notes.filter((n) => n.tone === 'blocker');
  const infos = notes.filter((n) => n.tone === 'info');
  return (
    <div className="flex flex-col gap-4 text-sm">
      {!preview.erased &&
        (preview.mode === 'deleted' ? (
          <p className="text-ink">
            Their record is removed with their vehicles, quotes, messages, files and form answers.
          </p>
        ) : (
          <ul className="text-ink flex list-disc flex-col gap-1.5 pl-5">
            <li>
              <span className="font-medium">Removed:</span> their name, contact details, addresses,
              notes, tags and custom fields; vehicle VINs, plates and notes; messages, files, form
              answers and signatures; notes on their jobs, quotes, invoices and payments; shared job
              report links and portal access.
            </li>
            <li>
              <span className="font-medium">Kept:</span> jobs, quotes, invoices, payments and
              memberships, with their amounts, numbers and dates, under “Deleted customer”.
              Repeating appointments are ended.
            </li>
          </ul>
        ))}
      <p className="text-muted">Any duplicate records merged into this customer are included.</p>
      {blockers.length > 0 && (
        <div
          role="alert"
          className="bg-danger-soft text-danger-ink rounded-card flex gap-3 px-4 py-3"
        >
          <CircleAlert className="size-5 shrink-0" aria-hidden="true" />
          <ul className="flex flex-col gap-1">
            {blockers.map((note) => (
              <li key={note.text}>{note.text}</li>
            ))}
          </ul>
        </div>
      )}
      {infos.length > 0 && (
        <div className="border-primary/25 bg-primary-soft text-primary-ink rounded-card flex gap-3 border px-4 py-3">
          <Info className="size-5 shrink-0" aria-hidden="true" />
          <div>
            <p className="font-medium">Before that, this also happens:</p>
            <ul className="mt-1 flex list-disc flex-col gap-1 pl-5">
              {infos.map((note) => (
                <li key={note.text}>{note.text}</li>
              ))}
            </ul>
          </div>
        </div>
      )}
    </div>
  );
}
