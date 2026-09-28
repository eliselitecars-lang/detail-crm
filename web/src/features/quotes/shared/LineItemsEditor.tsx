import { Pencil, Plus, Receipt, Trash2 } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import {
  Badge,
  Button,
  ConfirmDialog,
  DropdownMenu,
  EmptyState,
  IconButton,
  SectionCard,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import type { PickerVehicle } from './api';
import { CatalogDialog } from './CatalogDialog';
import { useShopFees } from './fees';
import { formatQuantity, vehicleLabel } from './format';
import { LineDialog, type LineOptionChoice } from './LineDialog';
import { groupLines, UNGROUPED, type DocLine, type LineDraft, type LinePatch } from './lines';

/** How to group the list (e.g. an invoice's lines by the job they bill). */
export interface LineGrouping {
  keyOf: (line: DocLine) => string | null;
  titleOf: (key: string) => string;
  /** Group order (keys not listed follow in order of appearance). */
  order?: readonly string[];
}

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
  /** Card title (default "Line items"). */
  title?: ReactNode;
  /** Accessible name of the list (default "Line items"). */
  listLabel?: string;
  /** Card description when editable. */
  description?: ReactNode;
  /** The customer's vehicles: per-line vehicle picker + labels (fleets). */
  vehicles?: readonly PickerVehicle[];
  /** Quotes with proposal options: the options a line may belong to. */
  options?: readonly LineOptionChoice[];
  /** Option new lines go to (the option tab being edited; null = every option). */
  defaultOptionId?: string | null;
  grouping?: LineGrouping;
  /** Preset fees: adds a fee line (the server prices it). Omit to hide "Add fee". */
  onAddFee?: (feeId: string) => Promise<unknown>;
  /** The document has a discount: lines it doesn't apply to get a hint. */
  documentDiscounted?: boolean;
  /** Text of the empty state when editable. */
  emptyDescription?: string;
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
  title = 'Line items',
  listLabel = 'Line items',
  description,
  vehicles,
  options,
  defaultOptionId = null,
  grouping,
  onAddFee,
  documentDiscounted = false,
  emptyDescription = 'Add services from your catalog or a custom line.',
}: LineItemsEditorProps) {
  const toast = useToast();
  const [dialog, setDialog] = useState<DialogState>({ kind: 'none' });
  const [removing, setRemoving] = useState<DocLine | null>(null);
  const [removeBusy, setRemoveBusy] = useState(false);
  const [feeBusy, setFeeBusy] = useState(false);
  const fees = useShopFees(editable && onAddFee !== undefined);
  const hasOptions = (options?.length ?? 0) > 0;

  const close = () => setDialog({ kind: 'none' });
  const withDefaults = (draft: LineDraft): LineDraft => ({
    ...draft,
    ...(hasOptions && draft.option_id === undefined ? { option_id: defaultOptionId } : {}),
  });

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
          ...(draft.vehicle_id !== undefined && draft.vehicle_id !== dialog.line.vehicle_id
            ? { vehicle_id: draft.vehicle_id }
            : {}),
          ...(draft.option_id !== undefined && draft.option_id !== dialog.line.option_id
            ? { option_id: draft.option_id }
            : {}),
        });
        toast.success('Line updated');
      } else {
        await onAdd([withDefaults(draft)]);
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

  const addFee = async (feeId: string, name: string) => {
    if (!onAddFee) return;
    setFeeBusy(true);
    try {
      await onAddFee(feeId);
      toast.success(`${name} added`);
    } catch (error) {
      toast.error(error);
    } finally {
      setFeeBusy(false);
    }
  };

  const vehicleName = (id: string | null) => {
    if (!id || !vehicles) return null;
    const vehicle = vehicles.find((v) => v.id === id);
    return vehicle ? vehicleLabel(vehicle) : null;
  };

  const feeList = fees.data ?? [];
  const actions = editable ? (
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
      {onAddFee && feeList.length > 0 && (
        <DropdownMenu
          items={feeList.map((fee) => ({
            key: fee.id,
            label: `${fee.name} · ${formatCents(fee.amount_cents, { currency })}`,
            onSelect: () => void addFee(fee.id, fee.name),
          }))}
          trigger={(props) => (
            <Button
              {...props}
              size="sm"
              variant="ghost"
              loading={feeBusy}
              leadingIcon={<Receipt className="size-4" aria-hidden="true" />}
            >
              Add fee
            </Button>
          )}
        />
      )}
    </div>
  ) : undefined;

  const groups =
    grouping && lines.length > 0
      ? groupLines(lines, grouping.keyOf, grouping.titleOf, grouping.order)
      : null;
  const showHeaders =
    groups !== null && (groups.length > 1 || groups.some((g) => g.key !== UNGROUPED));

  const renderLine = (line: DocLine) => {
    const vehicle = vehicleName(line.vehicle_id);
    return (
      <li key={line.id} className="flex items-start gap-3 px-4 py-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-ink text-sm font-medium break-words">{line.name}</span>
            {line.optional && (
              <Badge tone={line.selected ? 'success' : 'neutral'}>
                {line.selected ? 'Optional · chosen' : 'Optional'}
              </Badge>
            )}
            {line.fee_id && <Badge tone="neutral">Fee</Badge>}
            {!line.taxable && <Badge tone="neutral">Not taxable</Badge>}
            {documentDiscounted && !line.discount_eligible && (
              <Badge tone="neutral">No discount</Badge>
            )}
          </div>
          {line.description && (
            <p className="text-muted mt-0.5 text-xs break-words whitespace-pre-line">
              {line.description}
            </p>
          )}
          <p className="text-muted mt-1 text-xs tabular-nums">
            {vehicle && <span className="text-ink">{vehicle} · </span>}
            {formatQuantity(line.quantity)} × {formatCents(line.unit_price_cents, { currency })}
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
    );
  };

  return (
    <SectionCard
      title={title}
      description={editable ? description : lockedMessage}
      flush
      actions={actions}
    >
      {lines.length === 0 ? (
        <EmptyState
          compact
          title="No line items yet"
          description={editable ? emptyDescription : 'Nothing was added.'}
        />
      ) : groups && showHeaders ? (
        <div aria-label={listLabel} role="group">
          {groups.map((group) => (
            <section key={group.key} aria-label={group.title}>
              <h3 className="bg-subtle text-muted border-line border-y px-4 py-1.5 text-xs font-semibold tracking-wide uppercase">
                {group.title}
              </h3>
              <ul className="divide-line divide-y" aria-label={`${group.title} lines`}>
                {group.lines.map(renderLine)}
              </ul>
            </section>
          ))}
        </div>
      ) : (
        <ul className="divide-line divide-y" aria-label={listLabel}>
          {lines.map(renderLine)}
        </ul>
      )}

      <LineDialog
        open={dialog.kind === 'line'}
        onClose={close}
        line={dialog.kind === 'line' ? dialog.line : null}
        supportsOptional={supportsOptional}
        {...(vehicles ? { vehicles } : {})}
        {...(options ? { options } : {})}
        defaultOptionId={defaultOptionId}
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
          await onAdd(drafts.map(withDefaults));
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
