import { useState } from 'react';
import {
  Badge,
  Button,
  Checkbox,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  MoneyInput,
  SearchInput,
  Select,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import {
  useAddLineItems,
  useCatalog,
  usePricing,
  useUpdateLineItem,
  useVehicleCategories,
  type JobDetail,
  type LineDraft,
  type LineItem,
} from '../../api';
import { formatDuration, vehicleLabel } from '../../model';
import { useCustomerVehicles, type VehicleOption } from '../../newJobApi';

// ---------------------------------------------------------------------------
// Vehicle picker (P-7: a line can name another of the customer's vehicles —
// fleets / dealers put several vehicles on one job)
// ---------------------------------------------------------------------------

/** The customer's vehicles plus the job's own (even if archived since). */
function useLineVehicles(job: JobDetail): VehicleOption[] {
  const vehicles = useCustomerVehicles(job.customer_id);
  const list = [...(vehicles.data ?? [])];
  if (job.vehicle && !list.some((v) => v.id === job.vehicle?.id)) list.unshift(job.vehicle);
  return list;
}

function VehiclePicker({
  vehicles,
  value,
  onChange,
}: {
  vehicles: readonly VehicleOption[];
  value: string;
  onChange: (vehicleId: string) => void;
}) {
  return (
    <FormField label="Vehicle" help="Which of the customer’s vehicles this line is for.">
      <Select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        options={[
          { value: '', label: 'No specific vehicle' },
          ...vehicles.map((v) => ({ value: v.id, label: vehicleLabel(v, true) })),
        ]}
      />
    </FormField>
  );
}

// ---------------------------------------------------------------------------
// Custom / edit line
// ---------------------------------------------------------------------------

export interface LineDialogProps {
  job: JobDetail;
  /** Editing an existing line, or null to add a custom line. */
  line: LineItem | null;
  nextSort: number;
  onClose: () => void;
}

function parseQuantity(text: string): number | null {
  const value = Number(text);
  if (!Number.isFinite(value) || value <= 0 || value > 99_999_999) return null;
  if (!/^\d+(\.\d{1,2})?$/.test(text.trim())) return null;
  return value;
}

export function LineDialog({ job, line, nextSort, onClose }: LineDialogProps) {
  const { currency } = useShop();
  const toast = useToast();
  const add = useAddLineItems(job.id);
  const update = useUpdateLineItem();
  const [name, setName] = useState(line?.name ?? '');
  const [description, setDescription] = useState(line?.description ?? '');
  const [quantity, setQuantity] = useState(line ? String(line.quantity) : '1');
  const [price, setPrice] = useState<number | null>(line?.unit_price_cents ?? null);
  const [discount, setDiscount] = useState<number | null>(line?.discount_cents ?? 0);
  const [taxable, setTaxable] = useState(line?.taxable ?? true);
  const [duration, setDuration] = useState(line ? String(line.duration_minutes) : '0');
  const [vehicleId, setVehicleId] = useState(
    line ? (line.vehicle_id ?? '') : (job.vehicle_id ?? ''),
  );
  const vehicles = useLineVehicles(job);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const pending = add.isPending || update.isPending;

  const save = async () => {
    const next: Record<string, string> = {};
    const qty = parseQuantity(quantity);
    const minutes = Number(duration);
    if (!name.trim()) next.name = 'Enter a name.';
    if (qty === null) next.quantity = 'Enter a quantity above 0 (up to 2 decimals).';
    if (price === null || price < 0) next.price = 'Enter a price.';
    if (discount === null || discount < 0) next.discount = 'Enter a discount (0 for none).';
    if (!Number.isInteger(minutes) || minutes < 0 || minutes > 44640) {
      next.duration = 'Enter whole minutes.';
    }
    setErrors(next);
    if (Object.keys(next).length > 0 || qty === null || price === null || discount === null) return;
    const values = {
      name: name.trim(),
      description: description.trim() || null,
      quantity: qty,
      unit_price_cents: price,
      discount_cents: discount,
      taxable,
      duration_minutes: minutes,
      vehicle_id: vehicleId || null,
    };
    try {
      if (line) {
        await update.mutateAsync({ id: line.id, patch: values });
        toast.success('Line updated');
      } else {
        await add.mutateAsync({
          lines: [{ ...values, service_id: null }],
          startSort: nextSort,
        });
        toast.success('Line added');
      }
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      title={line ? 'Edit line item' : 'Add custom item'}
      description="Totals and tax are recalculated by the server when you save."
      size="md"
      dismissible={!pending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={pending}>
            Cancel
          </Button>
          <Button loading={pending} onClick={() => void save()}>
            {line ? 'Save' : 'Add item'}
          </Button>
        </>
      }
    >
      <div className="grid grid-cols-2 gap-3">
        <FormField label="Name" required error={errors.name} className="col-span-2">
          <Input value={name} maxLength={200} onChange={(e) => setName(e.target.value)} />
        </FormField>
        <FormField label="Description" className="col-span-2">
          <Textarea
            rows={2}
            maxLength={5000}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </FormField>
        <FormField label="Quantity" required error={errors.quantity}>
          <Input
            inputMode="decimal"
            value={quantity}
            onChange={(e) => setQuantity(e.target.value)}
          />
        </FormField>
        <FormField label="Unit price" required error={errors.price}>
          <MoneyInput value={price} onChange={setPrice} />
        </FormField>
        <FormField
          label="Line discount"
          error={errors.discount}
          help={`In ${currency.toUpperCase()}`}
        >
          <MoneyInput value={discount} onChange={setDiscount} />
        </FormField>
        <FormField label="Duration (minutes)" error={errors.duration}>
          <Input
            inputMode="numeric"
            value={duration}
            onChange={(e) => setDuration(e.target.value)}
          />
        </FormField>
        {vehicles.length > 0 && (
          <div className="col-span-2">
            <VehiclePicker vehicles={vehicles} value={vehicleId} onChange={setVehicleId} />
          </div>
        )}
        <Checkbox
          className="col-span-2"
          label="Taxable"
          checked={taxable}
          onChange={(e) => setTaxable(e.target.checked)}
        />
      </div>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------
// Add from catalog (priced by price_services for the job's vehicle)
// ---------------------------------------------------------------------------

export interface CatalogDialogProps {
  job: JobDetail;
  nextSort: number;
  onClose: () => void;
}

export function CatalogDialog({ job, nextSort, onClose }: CatalogDialogProps) {
  const { currency } = useShop();
  const toast = useToast();
  const catalog = useCatalog();
  const categories = useVehicleCategories();
  const add = useAddLineItems(job.id);
  const [search, setSearch] = useState('');
  const [selected, setSelected] = useState<string[]>([]);
  const vehicles = useLineVehicles(job);
  const [vehicleId, setVehicleId] = useState(job.vehicle_id ?? '');
  const [categoryId, setCategoryId] = useState(job.vehicle?.category_id ?? '');
  // A shop without vehicle sizes prices every service at its base price.
  const noSizes = categories.isSuccess && categories.data.length === 0;

  const pricing = usePricing(
    (categoryId || noSizes) && selected.length > 0
      ? {
          customerId: job.customer_id,
          vehicleCategoryId: categoryId || null,
          vehicleId: vehicleId || null,
          serviceIds: selected,
        }
      : null,
  );

  const q = search.trim().toLowerCase();
  const services = (catalog.data?.services ?? []).filter(
    (s) => !q || s.name.toLowerCase().includes(q),
  );
  const toggle = (id: string) =>
    setSelected((ids) => (ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id]));

  const lines = pricing.data?.lines ?? [];
  const priced = selected.length > 0 && !pricing.isFetching && pricing.data?.lines !== undefined;
  const missingPrice = lines.some((l) => l.unit_price_cents === null);

  const save = async () => {
    const drafts: LineDraft[] = lines.map((l) => ({
      service_id: l.service_id,
      vehicle_id: vehicleId || null,
      name: l.name,
      description: l.note,
      quantity: 1,
      unit_price_cents: l.unit_price_cents ?? 0,
      discount_cents: 0,
      taxable: l.taxable,
      duration_minutes: l.duration_minutes ?? 0,
    }));
    try {
      await add.mutateAsync({ lines: drafts, startSort: nextSort });
      toast.success(drafts.length === 1 ? 'Service added' : `${drafts.length} services added`);
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      title="Add services"
      description="Prices come from your catalog for the vehicle size, including memberships."
      size="lg"
      dismissible={!add.isPending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={add.isPending}>
            Cancel
          </Button>
          <Button
            loading={add.isPending}
            disabled={!priced || missingPrice || lines.length === 0}
            onClick={() => void save()}
          >
            {selected.length > 1 ? `Add ${selected.length} services` : 'Add service'}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        {vehicles.length > 1 && (
          <VehiclePicker
            vehicles={vehicles}
            value={vehicleId}
            onChange={(id) => {
              setVehicleId(id);
              // price for the picked vehicle's size
              const size = vehicles.find((v) => v.id === id)?.category_id;
              if (size) setCategoryId(size);
            }}
          />
        )}
        {!noSizes && (
          <FormField
            label="Vehicle size"
            help={job.vehicle?.category_id ? undefined : 'Pick a size to price services.'}
          >
            <Select
              value={categoryId}
              onChange={(e) => setCategoryId(e.target.value)}
              placeholder="Choose a size"
              options={(categories.data ?? []).map((c) => ({ value: c.id, label: c.name }))}
            />
          </FormField>
        )}
        <SearchInput label="Search services" value={search} onChange={setSearch} debounceMs={0} />
        {catalog.isPending ? (
          <LoadingState label="Loading catalog…" />
        ) : catalog.isError ? (
          <ErrorState compact error={catalog.error} onRetry={() => void catalog.refetch()} />
        ) : services.length === 0 ? (
          <EmptyState
            compact
            title="No services found"
            description="Add services in the catalog."
          />
        ) : (
          <fieldset className="border-line rounded-control max-h-64 overflow-y-auto border p-3">
            <legend className="sr-only">Services</legend>
            <div className="flex flex-col gap-2.5">
              {services.map((s) => {
                const line = lines.find((l) => l.service_id === s.id);
                return (
                  <Checkbox
                    key={s.id}
                    label={s.name}
                    description={
                      line
                        ? line.unit_price_cents === null
                          ? 'No price for this size'
                          : `${formatCents(line.unit_price_cents, { currency })} · ${formatDuration(line.duration_minutes ?? 0)}${line.membership_included ? ' · included with membership' : ''}`
                        : formatDuration(s.duration_minutes)
                    }
                    checked={selected.includes(s.id)}
                    onChange={() => toggle(s.id)}
                  />
                );
              })}
            </div>
          </fieldset>
        )}
        {pricing.isError && (
          <ErrorState compact error={pricing.error} onRetry={() => void pricing.refetch()} />
        )}
        {missingPrice && (
          <p role="alert" className="text-warning-ink text-sm">
            Some services have no price for this vehicle size. Set a price in the catalog or add a
            custom item instead.
          </p>
        )}
        {lines.some((l) => l.membership_included) && (
          <Badge tone="success">Membership applied</Badge>
        )}
      </div>
    </Dialog>
  );
}
