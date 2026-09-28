import { FlaskConical, Pencil, Plus, Trash2 } from 'lucide-react';
import { useId, useState } from 'react';
import { Link } from 'react-router';
import {
  Button,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  IconButton,
  Input,
  LoadingState,
  SectionCard,
  Select,
  useToast,
} from '@/components/ui';
import {
  useDeleteConsumable,
  useProductOptions,
  useSaveConsumable,
  useServiceConsumables,
  useVehicleCategories,
  type ConsumableRow,
} from '../api';
import { formatQuantity, parseQuantity, type ServiceRow } from '../model';

/**
 * Materials a service uses per unit sold (P-28). When a job with the service
 * is completed, the server deducts them from stock (a vehicle-size rule for a
 * product wins over the every-size rule for it). Managers only.
 */
export function ConsumablesCard({
  service,
  canManage,
}: {
  service: ServiceRow;
  canManage: boolean;
}) {
  const toast = useToast();
  const consumables = useServiceConsumables(service.id);
  const products = useProductOptions();
  const categories = useVehicleCategories();
  const remove = useDeleteConsumable(service.id);
  const [editing, setEditing] = useState<ConsumableRow | 'new' | null>(null);
  const [deleting, setDeleting] = useState<ConsumableRow | null>(null);
  const rows = consumables.data ?? [];
  const productOf = new Map((products.data ?? []).map((p) => [p.id, p]));
  const categoryName = new Map((categories.data ?? []).map((c) => [c.id, c.name]));
  const hasProducts = (products.data ?? []).some((p) => p.archived_at === null);

  let body;
  if (consumables.isPending || products.isPending)
    body = <LoadingState variant="rows" rows={2} label="Loading materials…" />;
  else if (consumables.error || products.error)
    body = (
      <ErrorState
        compact
        error={consumables.error ?? products.error}
        title="Couldn’t load materials"
        onRetry={() => {
          void consumables.refetch();
          void products.refetch();
        }}
        retrying={consumables.isRefetching || products.isRefetching}
      />
    );
  else if (rows.length === 0)
    body = (
      <EmptyState
        compact
        icon={<FlaskConical aria-hidden="true" />}
        title="No materials"
        description={
          hasProducts
            ? 'List the products this item uses so stock goes down when a job is completed.'
            : 'Add your products in Inventory first, then list what this item uses.'
        }
        action={
          canManage ? (
            hasProducts ? (
              <Button size="sm" leadingIcon={<Plus />} onClick={() => setEditing('new')}>
                Add material
              </Button>
            ) : (
              <Link
                to="/app/inventory"
                className="text-primary-ink text-sm font-medium hover:underline"
              >
                Open inventory
              </Link>
            )
          ) : undefined
        }
      />
    );
  else
    body = (
      <ul className="divide-line divide-y" aria-label="Materials used">
        {rows.map((row) => {
          const product = productOf.get(row.product_id);
          return (
            <li key={row.id} className="flex items-center gap-3 px-4 py-3 sm:px-5">
              <div className="min-w-0 flex-1">
                <p className="text-ink truncate text-sm font-medium">
                  {product?.name ?? 'Product'}
                  {product && product.archived_at !== null && (
                    <span className="text-muted font-normal"> (archived, not deducted)</span>
                  )}
                </p>
                <p className="text-muted text-xs">
                  {formatQuantity(row.quantity)} {product?.unit ?? ''} per unit ·{' '}
                  {row.vehicle_category_id
                    ? (categoryName.get(row.vehicle_category_id) ?? 'One vehicle size')
                    : 'Every vehicle size'}
                </p>
              </div>
              {canManage && (
                <div className="flex shrink-0 items-center gap-0.5">
                  <IconButton
                    label={`Edit ${product?.name ?? 'material'}`}
                    icon={<Pencil className="size-4" />}
                    size="sm"
                    onClick={() => setEditing(row)}
                  />
                  <IconButton
                    label={`Remove ${product?.name ?? 'material'}`}
                    icon={<Trash2 className="size-4" />}
                    size="sm"
                    variant="danger"
                    onClick={() => setDeleting(row)}
                  />
                </div>
              )}
            </li>
          );
        })}
      </ul>
    );

  return (
    <>
      <SectionCard
        title="Materials used"
        description="Deducted from inventory when a job with this item is completed (per unit on the job)."
        flush
        actions={
          canManage && rows.length > 0 ? (
            <Button size="sm" leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              Add material
            </Button>
          ) : undefined
        }
      >
        {body}
      </SectionCard>
      {editing !== null && (
        <ConsumableDialog
          serviceId={service.id}
          consumable={editing === 'new' ? null : editing}
          existing={rows}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        loading={remove.isPending}
        title="Remove this material?"
        description="Stock already deducted for completed jobs stays as it is."
        confirmLabel="Remove"
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Material removed');
          } catch (error) {
            toast.error(error);
          } finally {
            setDeleting(null);
          }
        }}
      />
    </>
  );
}

function ConsumableDialog({
  serviceId,
  consumable,
  existing,
  onClose,
}: {
  serviceId: string;
  consumable: ConsumableRow | null;
  existing: readonly ConsumableRow[];
  onClose: () => void;
}) {
  const toast = useToast();
  const formId = useId();
  const save = useSaveConsumable(serviceId);
  const products = useProductOptions();
  const categories = useVehicleCategories();
  const [productId, setProductId] = useState(consumable?.product_id ?? '');
  const [categoryId, setCategoryId] = useState(consumable?.vehicle_category_id ?? '');
  const [quantity, setQuantity] = useState(consumable ? formatQuantity(consumable.quantity) : '1');
  const [errors, setErrors] = useState<Partial<Record<'product' | 'quantity', string>>>({});
  const product = (products.data ?? []).find((p) => p.id === productId);
  const options = (products.data ?? [])
    .filter((p) => p.archived_at === null || p.id === consumable?.product_id)
    .map((p) => ({ value: p.id, label: p.sku ? `${p.name} (${p.sku})` : p.name }));

  const submit = async () => {
    const next: typeof errors = {};
    if (!productId) next.product = 'Choose a product.';
    const qty = parseQuantity(quantity);
    if (qty === null) next.quantity = 'Enter a quantity above 0 (up to 3 decimals).';
    const duplicate = existing.some(
      (r) =>
        r.id !== consumable?.id &&
        r.product_id === productId &&
        (r.vehicle_category_id ?? '') === categoryId,
    );
    if (productId && duplicate)
      next.product = 'This product is already listed for that vehicle size.';
    setErrors(next);
    if (Object.keys(next).length > 0 || qty === null) return;
    try {
      await save.mutateAsync({
        ...(consumable ? { id: consumable.id } : {}),
        productId,
        vehicleCategoryId: categoryId === '' ? null : categoryId,
        quantity: qty,
      });
      toast.success(consumable ? 'Material saved' : 'Material added');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      title={consumable ? 'Edit material' : 'Add material'}
      size="md"
      footer={
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {consumable ? 'Save' : 'Add material'}
          </Button>
        </div>
      }
    >
      <form
        id={formId}
        noValidate
        className="flex flex-col gap-4"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <FormField label="Product" required error={errors.product}>
          <Select
            placeholder="Choose a product"
            value={productId}
            onChange={(e) => setProductId(e.target.value)}
            options={options}
          />
        </FormField>
        <FormField
          label="Vehicle size"
          help="A rule for one size replaces the every-size rule of the same product for that size."
        >
          <Select
            value={categoryId}
            onChange={(e) => setCategoryId(e.target.value)}
            options={[
              { value: '', label: 'Every vehicle size' },
              ...(categories.data ?? []).map((c) => ({ value: c.id, label: c.name })),
            ]}
          />
        </FormField>
        <FormField
          label="Quantity per unit"
          required
          error={errors.quantity}
          help={product ? `In ${product.unit}, for each unit of this item on a job.` : undefined}
        >
          <Input
            inputMode="decimal"
            value={quantity}
            onChange={(e) => setQuantity(e.target.value)}
            {...(product ? { trailing: product.unit } : {})}
          />
        </FormField>
      </form>
    </Dialog>
  );
}
