import { ArrowDown, ArrowUp, ChevronDown, Pencil, Plus, Receipt, Tag, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { useNavigate } from 'react-router';
import {
  Badge,
  Button,
  buttonClasses,
  ConfirmDialog,
  DropdownMenu,
  EmptyState,
  ErrorState,
  IconButton,
  LoadingState,
  SectionCard,
  useToast,
} from '@/components/ui';
import { formatBps, formatCents } from '@/lib/money';
import { useShopFees } from '@/features/settings/data/fees';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import {
  useAddFeeLine,
  useDeleteLineItem,
  useLineItems,
  useMoveLineItem,
  type JobDetail,
  type LineItem,
} from '../../api';
import { vehicleLabel } from '../../model';
import { useCustomerVehicles } from '../../newJobApi';
import { DiscountDialog } from './DiscountDialog';
import { CatalogDialog, LineDialog } from './LineItemDialogs';

type DialogState =
  | { kind: 'catalog' }
  | { kind: 'custom' }
  | { kind: 'edit'; line: LineItem }
  | { kind: 'discount' }
  | null;

export function LineItemsCard({ job }: { job: JobDetail }) {
  const { currency } = useShop();
  const canManage = useCan('jobs.manage');
  const canSeeMoney = useCan('invoices.viewAssigned');
  const toast = useToast();
  const lines = useLineItems(job.id);
  const move = useMoveLineItem(job.id);
  const remove = useDeleteLineItem();
  const addFee = useAddFeeLine(job.id);
  const navigate = useNavigate();
  const canSettings = useCan('settings.view');
  const fees = useShopFees();
  const vehicles = useCustomerVehicles(canManage ? job.customer_id : null);
  const [dialog, setDialog] = useState<DialogState>(null);
  const [deleting, setDeleting] = useState<LineItem | null>(null);
  const money = (cents: number | null) => formatCents(cents, { currency });

  const rows = lines.data ?? [];
  const nextSort = rows.reduce((max, l) => Math.max(max, l.sort), 0) + 1;

  const onMove = (index: number, delta: -1 | 1) => {
    if (!rows[index] || !rows[index + delta]) return;
    move.mutateAsync({ rows, index, delta }).catch((error: unknown) => toast.error(error));
  };

  const activeFees = (fees.data ?? []).filter((f) => f.active);
  const onAddFee = async (feeId: string, name: string) => {
    try {
      await addFee.mutateAsync(feeId);
      toast.success(`${name} added`);
    } catch (error) {
      toast.error(error);
    }
  };
  /** A line's vehicle when it isn't the job's own (P-7: several vehicles on one job). */
  const otherVehicle = (line: LineItem) => {
    if (!line.vehicle_id || line.vehicle_id === job.vehicle_id) return null;
    const v = (vehicles.data ?? []).find((x) => x.id === line.vehicle_id);
    return v ? vehicleLabel(v) : 'Another vehicle';
  };

  const discountLabel =
    job.coupon_id !== null
      ? 'Coupon'
      : job.discount_kind === 'percent'
        ? `Discount (${formatBps(job.discount_value)})`
        : 'Discount';

  return (
    <SectionCard
      title="Services & items"
      actions={
        canManage ? (
          <div className="flex flex-wrap gap-2">
            <Button
              size="sm"
              variant="secondary"
              leadingIcon={<Plus className="size-4" aria-hidden="true" />}
              onClick={() => setDialog({ kind: 'catalog' })}
            >
              Add service
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setDialog({ kind: 'custom' })}>
              Custom item
            </Button>
            {(activeFees.length > 0 || (fees.isSuccess && canSettings)) && (
              <DropdownMenu
                align="end"
                trigger={(props) => (
                  <button
                    type="button"
                    {...props}
                    disabled={addFee.isPending}
                    className={buttonClasses({ variant: 'ghost', size: 'sm' })}
                  >
                    <Receipt className="size-4" aria-hidden="true" />
                    Add fee
                    <ChevronDown className="size-3.5" aria-hidden="true" />
                  </button>
                )}
                items={
                  activeFees.length > 0
                    ? activeFees.map((fee) => ({
                        key: fee.id,
                        label: canSeeMoney ? `${fee.name} · ${money(fee.amount_cents)}` : fee.name,
                        onSelect: () => void onAddFee(fee.id, fee.name),
                      }))
                    : [
                        {
                          key: 'setup',
                          label: 'Set up preset fees…',
                          onSelect: () => void navigate('/app/settings/fees'),
                        },
                      ]
                }
              />
            )}
          </div>
        ) : undefined
      }
    >
      {lines.isPending ? (
        <LoadingState label="Loading items…" />
      ) : lines.isError ? (
        <ErrorState compact error={lines.error} onRetry={() => void lines.refetch()} />
      ) : rows.length === 0 ? (
        <EmptyState
          compact
          title="No services yet"
          description={canManage ? 'Add services from your catalog or a custom item.' : undefined}
        />
      ) : (
        <ul className="divide-line -my-2 divide-y">
          {rows.map((line, index) => (
            <li key={line.id} className="flex flex-wrap items-start gap-x-3 gap-y-1 py-3">
              <div className="min-w-0 flex-1">
                <p className="text-ink flex flex-wrap items-center gap-2 font-medium">
                  {line.name}
                  {line.fee_id && <Badge tone="neutral">Fee</Badge>}
                </p>
                {otherVehicle(line) && (
                  <p className="text-muted text-xs">For {otherVehicle(line)}</p>
                )}
                {line.description && (
                  <p className="text-muted text-xs whitespace-pre-line">{line.description}</p>
                )}
                <p className="text-muted mt-0.5 text-xs">
                  Qty {line.quantity}
                  {canSeeMoney && ` × ${money(line.unit_price_cents)}`}
                  {canSeeMoney && line.discount_cents > 0 && ` − ${money(line.discount_cents)}`}
                  {!line.taxable && ' · not taxed'}
                </p>
              </div>
              {canSeeMoney && (
                <p className="text-ink font-medium tabular-nums">{money(line.total_cents)}</p>
              )}
              {canManage && (
                <div className="flex w-full justify-end gap-0.5 sm:w-auto">
                  <IconButton
                    size="sm"
                    label={`Move ${line.name} up`}
                    icon={<ArrowUp className="size-4" />}
                    disabled={index === 0 || move.isPending}
                    onClick={() => onMove(index, -1)}
                  />
                  <IconButton
                    size="sm"
                    label={`Move ${line.name} down`}
                    icon={<ArrowDown className="size-4" />}
                    disabled={index === rows.length - 1 || move.isPending}
                    onClick={() => onMove(index, 1)}
                  />
                  <IconButton
                    size="sm"
                    label={`Edit ${line.name}`}
                    icon={<Pencil className="size-4" />}
                    onClick={() => setDialog({ kind: 'edit', line })}
                  />
                  <IconButton
                    size="sm"
                    variant="danger"
                    label={`Delete ${line.name}`}
                    icon={<Trash2 className="size-4" />}
                    onClick={() => setDeleting(line)}
                  />
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      {canSeeMoney && (
        <dl className="border-line mt-3 flex flex-col gap-1.5 border-t pt-3 text-sm">
          <div className="flex justify-between gap-3">
            <dt className="text-muted">Subtotal</dt>
            <dd className="tabular-nums">{money(job.subtotal_cents)}</dd>
          </div>
          <div className="flex items-center justify-between gap-3">
            <dt className="text-muted flex items-center gap-2">
              {discountLabel}
              {canManage && (
                <Button
                  size="sm"
                  variant="ghost"
                  leadingIcon={<Tag className="size-3.5" aria-hidden="true" />}
                  onClick={() => setDialog({ kind: 'discount' })}
                >
                  {job.discount_kind === 'none' && job.coupon_id === null ? 'Add' : 'Change'}
                </Button>
              )}
            </dt>
            <dd className="tabular-nums">
              {job.discount_cents > 0 ? `−${money(job.discount_cents)}` : money(0)}
            </dd>
          </div>
          <div className="flex justify-between gap-3">
            <dt className="text-muted">Tax ({formatBps(job.tax_rate_bps)})</dt>
            <dd className="tabular-nums">{money(job.tax_cents)}</dd>
          </div>
          <div className="text-ink flex justify-between gap-3 text-base font-semibold">
            <dt>Total</dt>
            <dd className="tabular-nums">{money(job.total_cents)}</dd>
          </div>
        </dl>
      )}

      {dialog?.kind === 'catalog' && (
        <CatalogDialog job={job} nextSort={nextSort} onClose={() => setDialog(null)} />
      )}
      {dialog?.kind === 'custom' && (
        <LineDialog job={job} line={null} nextSort={nextSort} onClose={() => setDialog(null)} />
      )}
      {dialog?.kind === 'edit' && (
        <LineDialog
          job={job}
          line={dialog.line}
          nextSort={nextSort}
          onClose={() => setDialog(null)}
        />
      )}
      {dialog?.kind === 'discount' && <DiscountDialog job={job} onClose={() => setDialog(null)} />}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title="Delete this item?"
        description={deleting ? `“${deleting.name}” is removed from the job.` : undefined}
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Item deleted');
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}
