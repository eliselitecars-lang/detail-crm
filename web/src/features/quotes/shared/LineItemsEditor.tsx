import { Pencil, Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  ConfirmDialog,
  EmptyState,
  IconButton,
  SectionCard,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { CatalogDialog } from './CatalogDialog';
import { formatQuantity } from './format';
import { LineDialog } from './LineDialog';
import type { DocLine, LineDraft, LinePatch } from './lines';

export interface LineItemsEditorProps {
  lines: readonly DocLine[];
  currency: string;
  /** Whether the server currently accepts line changes (SQL rules mirrored). */
  editable: boolean;
  /** Why editing is locked (shown when !editable). */
  lockedMessage?: string;
  /** Quotes: optional upsell lines. */
  supportsOptional: boolean;
  pricing: { customerId: string; vehicleId: string | null; vehicleCategoryId: string | null };
  onAdd: (drafts: LineDraft[]) => Promise<unknown>;
  onUpdate: (id: string, patch: LinePatch) => Promise<unknown>;
  onRemove: (id: string) => Promise<unknown>;
}

type DialogState = { kind: 'none' } | { kind: 'catalog' } | { kind: 'line'; line: DocLine | null };

export function LineItemsEditor({
  lines,
  currency,
  editable,
  lockedMessage,
  supportsOptional,
  pricing,
  onAdd,
  onUpdate,
  onRemove,
}: LineItemsEditorProps) {
  const toast = useToast();
  const [dialog, setDialog] = useState<DialogState>({ kind: 'none' });
  const [removing, setRemoving] = useState<DocLine | null>(null);
  const [removeBusy, setRemoveBusy] = useState(false);

  const close = () => setDialog({ kind: 'none' });

  const submitLine = async (draft: LineDraft) => {
    if (dialog.kind !== 'line') return;
    try {
      if (dialog.line) {
        await onUpdate(dialog.line.id, {
          name: draft.name,
          description: draft.description,
          quantity: draft.quantity,
          unit_price_cents: draft.unit_price_cents,
          discount_cents: draft.discount_cents,
          taxable: draft.taxable,
          ...(supportsOptional ? { optional: draft.optional } : {}),
        });
        toast.success('Line updated');
      } else {
        await onAdd([draft]);
        toast.success('Line added');
      }
    } catch (error) {
      toast.error(error);
      throw error;
    }
  };

  const confirmRemove = async () => {
    if (!removing) return;
    setRemoveBusy(true);
    try {
      await onRemove(removing.id);
      toast.success('Line removed');
      setRemoving(null);
    } catch (error) {
      toast.error(error);
    } finally {
      setRemoveBusy(false);
    }
  };

  return (
    <SectionCard
      title="Line items"
      description={editable ? undefined : lockedMessage}
      flush
      actions={
        editable ? (
          <div className="flex flex-wrap gap-2">
            <Button
              size="sm"
              variant="secondary"
              leadingIcon={<Plus className="size-4" aria-hidden="true" />}
              onClick={() => setDialog({ kind: 'catalog' })}
            >
              From catalog
            </Button>
            <Button
              size="sm"
              variant="ghost"
              leadingIcon={<Plus className="size-4" aria-hidden="true" />}
              onClick={() => setDialog({ kind: 'line', line: null })}
            >
              Custom line
            </Button>
          </div>
        ) : undefined
      }
    >
      {lines.length === 0 ? (
        <EmptyState
          compact
          title="No line items yet"
          description={
            editable ? 'Add services from your catalog or a custom line.' : 'Nothing was added.'
          }
        />
      ) : (
        <ul className="divide-line divide-y" aria-label="Line items">
          {lines.map((line) => (
            <li key={line.id} className="flex items-start gap-3 px-4 py-3">
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-ink text-sm font-medium break-words">{line.name}</span>
                  {line.optional && (
                    <Badge tone={line.selected ? 'success' : 'neutral'}>
                      {line.selected ? 'Optional · chosen' : 'Optional'}
                    </Badge>
                  )}
                  {!line.taxable && <Badge tone="neutral">Not taxable</Badge>}
                </div>
                {line.description && (
                  <p className="text-muted mt-0.5 text-xs break-words whitespace-pre-line">
                    {line.description}
                  </p>
                )}
                <p className="text-muted mt-1 text-xs tabular-nums">
                  {formatQuantity(line.quantity)} ×{' '}
                  {formatCents(line.unit_price_cents, { currency })}
                  {line.discount_cents > 0 &&
                    ` · discount ${formatCents(line.discount_cents, { currency })}`}
                </p>
              </div>
              <div className="flex shrink-0 flex-col items-end gap-1">
                <span className="text-ink text-sm font-medium tabular-nums">
                  {formatCents(line.total_cents, { currency })}
                </span>
                {editable && (
                  <div className="flex gap-1">
                    <IconButton
                      size="sm"
                      variant="ghost"
                      label={`Edit ${line.name}`}
                      icon={<Pencil className="size-4" />}
                      onClick={() => setDialog({ kind: 'line', line })}
                    />
                    <IconButton
                      size="sm"
                      variant="ghost"
                      label={`Remove ${line.name}`}
                      icon={<Trash2 className="size-4" />}
                      onClick={() => setRemoving(line)}
                    />
                  </div>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}

      <LineDialog
        open={dialog.kind === 'line'}
        onClose={close}
        line={dialog.kind === 'line' ? dialog.line : null}
        supportsOptional={supportsOptional}
        onSubmit={submitLine}
      />
      <CatalogDialog
        open={dialog.kind === 'catalog'}
        onClose={close}
        customerId={pricing.customerId}
        vehicleId={pricing.vehicleId}
        defaultCategoryId={pricing.vehicleCategoryId}
        currency={currency}
        supportsOptional={supportsOptional}
        onAdd={async (drafts) => {
          await onAdd(drafts);
          toast.success(drafts.length === 1 ? 'Item added' : `${drafts.length} items added`);
        }}
      />
      <ConfirmDialog
        open={removing !== null}
        onClose={() => setRemoving(null)}
        onConfirm={confirmRemove}
        loading={removeBusy}
        tone="danger"
        title="Remove this line?"
        description={removing ? `“${removing.name}” will be removed.` : undefined}
        confirmLabel="Remove"
      />
    </SectionCard>
  );
}
