import { useId, useState } from 'react';
import {
  Button,
  Dialog,
  FormField,
  Input,
  MoneyInput,
  RadioGroup,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useRecordMovement, useSaveProduct } from '../api';
import {
  formatQty,
  movementQuantity,
  productDraft,
  productWrite,
  type ManualMovementKind,
  type Product,
  type ProductDraft,
  type ProductErrors,
} from '../model';

/** Create / edit a product (stock levels change only through stock changes). */
export function ProductDialog({
  product,
  onClose,
}: {
  product: Product | null;
  onClose: () => void;
}) {
  const toast = useToast();
  const formId = useId();
  const save = useSaveProduct();
  const [draft, setDraft] = useState<ProductDraft>(() => productDraft(product));
  const [errors, setErrors] = useState<ProductErrors>({});
  const isNew = product === null;
  const set = (patch: Partial<ProductDraft>) => setDraft((prev) => ({ ...prev, ...patch }));

  const submit = async () => {
    const result = productWrite(draft, isNew);
    if (result.errors) {
      setErrors(result.errors);
      return;
    }
    setErrors({});
    try {
      await save.mutateAsync({ ...(product ? { id: product.id } : {}), values: result.values });
      toast.success(product ? 'Product saved' : 'Product added');
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
      title={product ? `Edit ${product.name}` : 'New product'}
      description={isNew ? 'Products are the supplies your services use.' : undefined}
      size="lg"
      footer={
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {product ? 'Save product' : 'Add product'}
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
        <div className="grid gap-4 sm:grid-cols-[2fr_1fr]">
          <FormField label="Name" required error={errors.name}>
            <Input
              value={draft.name}
              maxLength={120}
              onChange={(e) => set({ name: e.target.value })}
            />
          </FormField>
          <FormField label="SKU" error={errors.sku}>
            <Input
              value={draft.sku}
              maxLength={60}
              onChange={(e) => set({ sku: e.target.value })}
            />
          </FormField>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            label="Unit"
            required
            error={errors.unit}
            help="How it’s counted: bottle, oz, pad, roll…"
          >
            <Input
              value={draft.unit}
              maxLength={20}
              onChange={(e) => set({ unit: e.target.value })}
            />
          </FormField>
          <FormField
            label="Cost per unit"
            required
            error={errors.unitCostCents}
            help="What you pay; used for job and service profit."
          >
            <MoneyInput
              value={draft.unitCostCents}
              onChange={(unitCostCents) => set({ unitCostCents })}
            />
          </FormField>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            label="Reorder at"
            error={errors.reorderAt}
            help="You’re notified when stock falls to this level. Leave empty for no alert."
          >
            <Input
              inputMode="decimal"
              value={draft.reorderAt}
              onChange={(e) => set({ reorderAt: e.target.value })}
            />
          </FormField>
          <FormField label="Reorder quantity" error={errors.reorderQty}>
            <Input
              inputMode="decimal"
              value={draft.reorderQty}
              onChange={(e) => set({ reorderQty: e.target.value })}
            />
          </FormField>
        </div>
        {isNew && (
          <FormField
            label="In stock now"
            error={errors.openingStock}
            help="Recorded as the opening count. Later changes go through Receive, Adjust or Count."
          >
            <Input
              inputMode="decimal"
              value={draft.openingStock}
              onChange={(e) => set({ openingStock: e.target.value })}
              placeholder="0"
            />
          </FormField>
        )}
        <FormField label="Supplier" error={errors.supplier}>
          <Input
            value={draft.supplier}
            maxLength={120}
            onChange={(e) => set({ supplier: e.target.value })}
          />
        </FormField>
        <FormField label="Notes" error={errors.notes}>
          <Textarea
            rows={2}
            value={draft.notes}
            maxLength={5000}
            onChange={(e) => set({ notes: e.target.value })}
          />
        </FormField>
        <Switch
          label="Active"
          description="Inactive products are not deducted when jobs are completed."
          checked={draft.active}
          onCheckedChange={(active) => set({ active })}
        />
      </form>
    </Dialog>
  );
}

const KIND_COPY: Record<
  ManualMovementKind,
  { title: string; label: string; help: string; action: string; done: string }
> = {
  receive: {
    title: 'Receive stock',
    label: 'Quantity received',
    help: 'Adds to what’s on hand.',
    action: 'Receive',
    done: 'Stock received',
  },
  adjust: {
    title: 'Adjust stock',
    label: 'Change',
    help: 'A correction: negative for loss or damage (e.g. -2), positive for found stock.',
    action: 'Adjust',
    done: 'Stock adjusted',
  },
  count: {
    title: 'Count stock',
    label: 'Counted on hand',
    help: 'What you actually have now; the difference is recorded.',
    action: 'Save count',
    done: 'Count saved',
  },
};

/** Receive / adjust / count (record_inventory_movement). */
export function StockDialog({
  product,
  initialKind,
  onClose,
}: {
  product: Product;
  initialKind: ManualMovementKind;
  onClose: () => void;
}) {
  const toast = useToast();
  const formId = useId();
  const { currency } = useShop();
  const record = useRecordMovement();
  const [kind, setKind] = useState<ManualMovementKind>(initialKind);
  const [quantity, setQuantity] = useState('');
  const [costCents, setCostCents] = useState<number | null>(null);
  const [note, setNote] = useState('');
  const [error, setError] = useState<string | null>(null);
  const copy = KIND_COPY[kind];

  const submit = async () => {
    const parsed = movementQuantity(kind, quantity);
    if (parsed.error !== null) {
      setError(parsed.error);
      return;
    }
    setError(null);
    try {
      await record.mutateAsync({
        productId: product.id,
        kind,
        quantity: parsed.quantity,
        unitCostCents: kind === 'receive' ? costCents : null,
        note,
      });
      toast.success(copy.done, product.name);
      onClose();
    } catch (err) {
      toast.error(err);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!record.isPending}
      title={`${copy.title} · ${product.name}`}
      description={`On hand: ${formatQty(product.on_hand)} ${product.unit}`}
      size="md"
      footer={
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onClose} disabled={record.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={record.isPending}>
            {copy.action}
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
        <RadioGroup<ManualMovementKind>
          label="Type of change"
          value={kind}
          onChange={(next) => {
            setKind(next);
            setError(null);
          }}
          orientation="horizontal"
          options={[
            { value: 'receive', label: 'Receive' },
            { value: 'adjust', label: 'Adjust' },
            { value: 'count', label: 'Count' },
          ]}
        />
        <FormField label={copy.label} required error={error} help={copy.help}>
          <Input
            inputMode="decimal"
            value={quantity}
            onChange={(e) => setQuantity(e.target.value)}
            trailing={product.unit}
          />
        </FormField>
        {kind === 'receive' && (
          <FormField
            label="Cost per unit paid"
            help={`Optional. Becomes the product’s cost (now ${formatCents(product.unit_cost_cents, { currency })}).`}
          >
            <MoneyInput value={costCents} onChange={setCostCents} />
          </FormField>
        )}
        <FormField label="Note" help="Optional, e.g. the supplier invoice number.">
          <Input value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} />
        </FormField>
      </form>
    </Dialog>
  );
}
