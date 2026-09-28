import { ArrowRight, TriangleAlert } from 'lucide-react';
import { useState } from 'react';
import { useNavigate } from 'react-router';
import {
  Button,
  Dialog,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  useToast,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatPhone } from '@/lib/phone';
import { useShop } from '@/features/shop/shopContext';
import type { PickerCustomer } from '@/features/quotes/shared/api';
import { CustomerCombobox } from '@/features/quotes/shared/CustomerPicker';
import { customerName } from '@/features/quotes/shared/format';
import {
  mergeCountsText,
  useMergeCustomers,
  useMergePreview,
  type MergePreview,
} from '../parityApi';

export interface MergeCustomerDialogProps {
  open: boolean;
  onClose: () => void;
  /** The duplicate being merged away (its records move to the target). */
  source: { id: string; name: string };
}

/**
 * Owner / admin: merge this (duplicate) customer into another one. The
 * preview (merge_customers_preview) lists what moves and anything that
 * blocks the merge; confirming needs the target's name typed. The source is
 * kept, archived, as "Merged into …".
 */
export function MergeCustomerDialog({ open, onClose, source }: MergeCustomerDialogProps) {
  return (
    <Dialog
      open={open}
      onClose={onClose}
      size="lg"
      title={`Merge ${source.name} into another customer`}
      description="Vehicles, jobs, quotes, invoices, payments, messages and files move to the customer you choose. This can’t be undone."
    >
      {open && <MergeBody source={source} onClose={onClose} />}
    </Dialog>
  );
}

function MergeBody({
  source,
  onClose,
}: {
  source: { id: string; name: string };
  onClose: () => void;
}) {
  const [target, setTarget] = useState<PickerCustomer | null>(null);
  return (
    <div className="flex flex-col gap-4">
      <FormField label="Keep this customer" required help="The record everything is moved to.">
        <CustomerCombobox value={target} onChange={setTarget} excludeIds={[source.id]} />
      </FormField>
      {target ? (
        <MergePreviewPanel key={target.id} sourceId={source.id} target={target} onClose={onClose} />
      ) : (
        <div className="flex justify-end">
          <Button variant="secondary" onClick={onClose}>
            Cancel
          </Button>
        </div>
      )}
    </div>
  );
}

function MergePreviewPanel({
  sourceId,
  target,
  onClose,
}: {
  sourceId: string;
  target: PickerCustomer;
  onClose: () => void;
}) {
  const toast = useToast();
  const navigate = useNavigate();
  const preview = useMergePreview(sourceId, target.id);
  const merge = useMergeCustomers();
  const [typed, setTyped] = useState('');
  const targetName = customerName(target);

  if (preview.isPending)
    return <LoadingState variant="rows" rows={3} label="Checking the merge…" />;
  if (preview.isError) {
    return <ErrorState compact error={preview.error} onRetry={() => void preview.refetch()} />;
  }
  const data = preview.data;
  const blocking = data.conflicts.filter((c) => c.blocking);
  const notes = data.conflicts.filter((c) => !c.blocking);
  const confirmed = typed.trim().toLowerCase() === targetName.trim().toLowerCase();

  const run = async () => {
    try {
      const result = await merge.mutateAsync({ sourceId, targetId: target.id });
      toast.success(`Merged into ${targetName}`, mergeCountsText(result.moved));
      onClose();
      await navigate(`/app/customers/${result.target_id}`, { replace: true });
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <div className="flex flex-col gap-4">
      <div className="grid grid-cols-1 items-stretch gap-3 sm:grid-cols-[1fr_auto_1fr]">
        <SummaryCard title="Merge away" summary={data.source} />
        <ArrowRight className="text-muted hidden size-5 self-center sm:block" aria-hidden="true" />
        <SummaryCard title="Keep" summary={data.target} />
      </div>
      <p className="text-ink text-sm">
        <span className="font-medium">Moves: </span>
        {mergeCountsText(data.counts)}.
      </p>
      {blocking.length > 0 && (
        <div role="alert" className="bg-danger-soft text-danger-ink rounded-card px-4 py-3 text-sm">
          <p className="font-medium">These customers can’t be merged yet:</p>
          <ul className="mt-1 list-disc pl-5">
            {blocking.map((c) => (
              <li key={c.code}>{c.message}</li>
            ))}
          </ul>
        </div>
      )}
      {notes.length > 0 && (
        <div className="bg-warning-soft text-warning-ink rounded-card flex gap-3 px-4 py-3 text-sm">
          <TriangleAlert className="size-5 shrink-0" aria-hidden="true" />
          <ul className="flex flex-col gap-1">
            {notes.map((c) => (
              <li key={c.code}>{c.message}</li>
            ))}
          </ul>
        </div>
      )}
      {data.can_merge && (
        <FormField
          label={`Type “${targetName}” to confirm`}
          help="The duplicate is archived and shown as merged; its records now belong to the customer you keep."
        >
          <Input value={typed} autoComplete="off" onChange={(e) => setTyped(e.target.value)} />
        </FormField>
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={merge.isPending}>
          Cancel
        </Button>
        <Button
          variant="danger"
          disabled={!data.can_merge || !confirmed}
          loading={merge.isPending}
          onClick={() => void run()}
        >
          Merge customers
        </Button>
      </div>
    </div>
  );
}

function SummaryCard({ title, summary }: { title: string; summary: MergePreview['source'] }) {
  const { timezone } = useShop();
  return (
    <div className="border-line rounded-card border p-3 text-sm">
      <p className="text-muted text-xs font-medium tracking-wide uppercase">{title}</p>
      <p className="text-ink mt-1 font-medium break-words">{summary.name ?? 'Unnamed customer'}</p>
      <p className="text-muted text-xs break-words">
        {[summary.email, summary.phone ? formatPhone(summary.phone) : null]
          .filter(Boolean)
          .join(' · ') || 'No contact details'}
      </p>
      <p className="text-muted mt-1 text-xs">
        Customer since {formatDate(summary.created_at, timezone)}
        {summary.portal_linked ? ' · portal account' : ''}
      </p>
    </div>
  );
}
