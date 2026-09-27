import { useMemo, useState } from 'react';
import {
  Badge,
  Button,
  Checkbox,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  LoadingState,
  SearchInput,
  Select,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useCatalogServices, usePriceServices, useVehicleCategories } from './api';
import type { LineDraft } from './lines';

export interface CatalogDialogProps {
  open: boolean;
  onClose: () => void;
  customerId: string;
  vehicleId: string | null;
  /** The vehicle's size class, used as the default price category. */
  defaultCategoryId: string | null;
  currency: string;
  supportsOptional: boolean;
  onAdd: (drafts: LineDraft[]) => Promise<unknown>;
}

const KIND_LABEL: Record<string, string> = {
  service: 'Service',
  package: 'Package',
  addon: 'Add-on',
  product: 'Product',
};

/**
 * Pick catalog services; unit prices come from the price_services RPC for
 * the chosen vehicle category, or base prices when the shop has no vehicle
 * sizes (membership inclusions applied server-side).
 * Services without a price for that category cannot be added from here.
 */
export function CatalogDialog(props: CatalogDialogProps) {
  // Remount the body on open so selections start fresh each time.
  return (
    <Dialog
      open={props.open}
      onClose={props.onClose}
      title="Add from catalog"
      description="Prices come from your catalog for the vehicle size you choose."
      size="lg"
    >
      {props.open && <CatalogPicker {...props} />}
    </Dialog>
  );
}

function CatalogPicker({
  onClose,
  customerId,
  vehicleId,
  defaultCategoryId,
  currency,
  supportsOptional,
  onAdd,
}: CatalogDialogProps) {
  const categories = useVehicleCategories();
  const services = useCatalogServices();
  const [categoryId, setCategoryId] = useState(defaultCategoryId ?? '');
  const [selected, setSelected] = useState<string[]>([]);
  const [search, setSearch] = useState('');
  const [optional, setOptional] = useState(false);
  const [adding, setAdding] = useState(false);
  const [addError, setAddError] = useState<unknown>(null);

  // A shop without vehicle sizes prices every service at its base price.
  const noSizes = categories.isSuccess && categories.data.length === 0;
  const pricing = usePriceServices(
    (categoryId || noSizes) && selected.length > 0
      ? { customerId, vehicleCategoryId: categoryId || null, vehicleId, serviceIds: selected }
      : null,
  );

  const visible = useMemo(() => {
    const term = search.trim().toLowerCase();
    const list = services.data ?? [];
    return term ? list.filter((s) => s.name.toLowerCase().includes(term)) : list;
  }, [services.data, search]);

  const priced = pricing.data?.lines ?? [];
  const priceById = new Map(priced.map((line) => [line.service_id, line]));
  const unpriced = selected.filter((id) => {
    const line = priceById.get(id);
    return line !== undefined && line.unit_price_cents === null;
  });
  const pricingReady =
    selected.length > 0 && !pricing.isFetching && selected.every((id) => priceById.has(id));

  const toggle = (id: string) =>
    setSelected((current) =>
      current.includes(id) ? current.filter((x) => x !== id) : [...current, id],
    );

  const add = async () => {
    const drafts: LineDraft[] = [];
    for (const id of selected) {
      const line = priceById.get(id);
      if (!line || line.unit_price_cents === null) continue;
      drafts.push({
        service_id: line.service_id,
        name: line.name,
        description: line.note,
        quantity: 1,
        unit_price_cents: line.unit_price_cents,
        discount_cents: 0,
        taxable: line.taxable,
        optional: supportsOptional && optional,
        duration_minutes: line.duration_minutes ?? 0,
      });
    }
    if (drafts.length === 0) return;
    setAdding(true);
    setAddError(null);
    try {
      await onAdd(drafts);
      onClose();
    } catch (error) {
      setAddError(error);
    } finally {
      setAdding(false);
    }
  };

  if (categories.isPending || services.isPending) return <LoadingState label="Loading catalog…" />;
  if (categories.isError || services.isError) {
    return (
      <ErrorState
        compact
        error={categories.error ?? services.error}
        onRetry={() => {
          void categories.refetch();
          void services.refetch();
        }}
      />
    );
  }
  if ((services.data ?? []).length === 0) {
    return (
      <EmptyState
        compact
        title="Your catalog has no active services"
        description="Add services in Catalog, or add a custom line instead."
      />
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {!noSizes && (
        <FormField
          label="Vehicle size"
          required
          help="Catalog prices differ by vehicle size."
          error={categoryId ? undefined : 'Choose a vehicle size to see prices.'}
        >
          <Select
            value={categoryId}
            onChange={(event) => setCategoryId(event.target.value)}
            placeholder="Choose a size"
            options={(categories.data ?? []).map((c) => ({ value: c.id, label: c.name }))}
          />
        </FormField>
      )}
      <SearchInput label="Search services" value={search} onChange={setSearch} debounceMs={0} />
      <fieldset className="border-line rounded-control max-h-72 overflow-y-auto border">
        <legend className="sr-only">Services</legend>
        {visible.length === 0 ? (
          <p className="text-muted p-4 text-sm">No services match “{search}”.</p>
        ) : (
          <ul className="divide-line divide-y">
            {visible.map((service) => {
              const line = priceById.get(service.id);
              const isSelected = selected.includes(service.id);
              return (
                <li key={service.id} className="flex items-start justify-between gap-3 px-3 py-2.5">
                  <Checkbox
                    checked={isSelected}
                    onChange={() => toggle(service.id)}
                    label={service.name}
                    description={KIND_LABEL[service.kind] ?? service.kind}
                  />
                  <span className="text-ink shrink-0 text-sm tabular-nums">
                    {isSelected && line ? (
                      line.unit_price_cents === null ? (
                        <Badge tone="warning">No price</Badge>
                      ) : line.membership_included ? (
                        <Badge tone="success">Included</Badge>
                      ) : (
                        formatCents(line.unit_price_cents, { currency })
                      )
                    ) : null}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
      </fieldset>
      {supportsOptional && (
        <Checkbox
          checked={optional}
          onChange={(event) => setOptional(event.target.checked)}
          label="Add as optional items"
          description="The customer can choose them when approving the quote."
        />
      )}
      {pricing.isError && (
        <ErrorState compact error={pricing.error} onRetry={() => void pricing.refetch()} />
      )}
      {unpriced.length > 0 && (
        <p role="alert" className="text-warning-ink text-sm">
          Some selected services have no price for this vehicle size. Set a price in Catalog or add
          them as custom lines.
        </p>
      )}
      {addError !== null && <ErrorState compact error={addError} title="Couldn’t add items" />}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={adding}>
          Cancel
        </Button>
        <Button
          onClick={() => void add()}
          loading={adding || (selected.length > 0 && Boolean(categoryId) && pricing.isFetching)}
          disabled={!categoryId || !pricingReady || unpriced.length > 0}
        >
          {selected.length > 0
            ? `Add ${selected.length} item${selected.length === 1 ? '' : 's'}`
            : 'Add items'}
        </Button>
      </div>
    </div>
  );
}
