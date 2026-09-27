import { Link } from 'react-router';
import { useState } from 'react';
import {
  Button,
  ErrorState,
  Input,
  LoadingState,
  MoneyInput,
  SectionCard,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useSavePrices, useServicePrices, useVehicleCategories } from '../api';
import {
  buildPriceDrafts,
  formatDuration,
  planHasChanges,
  planPriceChanges,
  type PriceDraft,
  type PriceRow,
  type ServiceRow,
  type VehicleCategoryRow,
} from '../model';

/** Prices per vehicle category + base price, with per-row duration overrides. */
export function PriceGrid({ service, canManage }: { service: ServiceRow; canManage: boolean }) {
  const prices = useServicePrices(service.id);
  const categories = useVehicleCategories();
  const canEditCategories = useCan('settings.manage');

  let body;
  if (prices.isPending || categories.isPending)
    body = <LoadingState label="Loading prices…" variant="rows" rows={3} />;
  else if (prices.error || categories.error)
    body = (
      <ErrorState
        compact
        error={prices.error ?? categories.error}
        title="Couldn’t load prices"
        onRetry={() => {
          void prices.refetch();
          void categories.refetch();
        }}
      />
    );
  else {
    // Remount the editor whenever the saved data changes so drafts reset.
    const signature = JSON.stringify([
      prices.data.map((p) => [p.id, p.price_cents, p.duration_minutes]),
      categories.data.map((c) => c.id),
      service.duration_minutes,
    ]);
    body = (
      <PriceEditor
        key={signature}
        service={service}
        saved={prices.data}
        categories={categories.data}
        canManage={canManage}
      />
    );
  }

  return (
    <SectionCard
      title="Prices"
      description={
        <>
          The base price applies to any vehicle size without its own price.
          {categories.data?.length === 0 && (
            <>
              {' '}
              {canEditCategories ? (
                <Link to="/app/settings/vehicle-categories" className="text-primary-ink underline">
                  Add vehicle sizes in Settings
                </Link>
              ) : (
                'An owner or admin can add vehicle sizes in Settings'
              )}{' '}
              to price by size.
            </>
          )}
        </>
      }
      flush
    >
      {body}
    </SectionCard>
  );
}

function PriceEditor({
  service,
  saved,
  categories,
  canManage,
}: {
  service: ServiceRow;
  saved: PriceRow[];
  categories: VehicleCategoryRow[];
  canManage: boolean;
}) {
  const { currency } = useShop();
  const toast = useToast();
  const save = useSavePrices(service.id);
  const initial = buildPriceDrafts(saved, categories);
  const [drafts, setDrafts] = useState<PriceDraft[]>(initial);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const nameOf = new Map(categories.map((c) => [c.id, c.name]));
  const plan = planPriceChanges(drafts, saved);
  const dirty = planHasChanges(plan) || Object.keys(plan.errors).length > 0;

  const patch = (key: string | null, next: Partial<PriceDraft>) =>
    setDrafts((prev) => prev.map((d) => (d.vehicleCategoryId === key ? { ...d, ...next } : d)));

  const onSave = async () => {
    setErrors(plan.errors);
    if (Object.keys(plan.errors).length > 0) return;
    try {
      await save.mutateAsync(plan);
      toast.success('Prices saved');
    } catch (error) {
      toast.error(error);
    }
  };

  const label = (d: PriceDraft) =>
    d.vehicleCategoryId === null
      ? 'Base price'
      : (nameOf.get(d.vehicleCategoryId) ?? 'Vehicle size');

  return (
    <div>
      <table className="w-full text-sm">
        <caption className="sr-only">Prices by vehicle size</caption>
        <thead>
          <tr className="border-line bg-surface-2/60 border-b">
            <th
              scope="col"
              className="text-muted px-4 py-2.5 text-left text-xs font-semibold uppercase sm:px-5"
            >
              Vehicle size
            </th>
            <th
              scope="col"
              className="text-muted px-2 py-2.5 text-left text-xs font-semibold uppercase"
            >
              Price
            </th>
            <th
              scope="col"
              className="text-muted px-2 py-2.5 text-left text-xs font-semibold uppercase sm:pr-5"
            >
              Time
            </th>
          </tr>
        </thead>
        <tbody>
          {drafts.map((d) => {
            const key = d.vehicleCategoryId ?? '';
            const error = errors[key];
            const name = label(d);
            const short = d.vehicleCategoryId === null ? 'Base' : name;
            return (
              <tr key={key} className="border-line border-b align-top last:border-b-0">
                <th scope="row" className="text-ink px-4 py-3 text-left font-medium sm:px-5">
                  {name}
                  {error && (
                    <p role="alert" className="text-danger-ink mt-1 text-xs font-medium">
                      {error}
                    </p>
                  )}
                </th>
                {canManage ? (
                  <>
                    <td className="px-2 py-2">
                      <div className="w-28 sm:w-32">
                        <MoneyInput
                          aria-label={`${short} price`}
                          value={d.priceCents}
                          onChange={(cents) => patch(d.vehicleCategoryId, { priceCents: cents })}
                          placeholder={d.vehicleCategoryId === null ? 'Not set' : 'Base'}
                        />
                      </div>
                    </td>
                    <td className="px-2 py-2 sm:pr-5">
                      <Input
                        aria-label={`${short} time in minutes`}
                        inputMode="numeric"
                        value={d.duration}
                        onChange={(e) => patch(d.vehicleCategoryId, { duration: e.target.value })}
                        placeholder={String(service.duration_minutes)}
                        trailing="min"
                        className="w-24 sm:w-28"
                      />
                    </td>
                  </>
                ) : (
                  <>
                    <td className="tabular text-ink px-2 py-3">
                      {d.priceCents === null ? (
                        <span className="text-subtle">
                          {d.vehicleCategoryId === null ? 'Not set' : 'Base price'}
                        </span>
                      ) : (
                        formatCents(d.priceCents, { currency })
                      )}
                    </td>
                    <td className="tabular text-ink px-2 py-3 sm:pr-5">
                      {formatDuration(
                        d.duration === '' ? service.duration_minutes : Number(d.duration),
                      )}
                    </td>
                  </>
                )}
              </tr>
            );
          })}
        </tbody>
      </table>
      {canManage && (
        <div className="border-line flex flex-col gap-2 border-t px-4 py-3 sm:flex-row sm:items-center sm:justify-between sm:px-5">
          <p className="text-muted text-xs">
            Leave a size empty to use the base price. Empty time uses the service’s{' '}
            {formatDuration(service.duration_minutes)}.
          </p>
          <div className="flex gap-2">
            <Button
              variant="secondary"
              size="sm"
              disabled={!dirty || save.isPending}
              onClick={() => {
                setDrafts(initial);
                setErrors({});
              }}
            >
              Reset
            </Button>
            <Button
              size="sm"
              disabled={!dirty}
              loading={save.isPending}
              onClick={() => void onSave()}
            >
              Save prices
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}
