import { useState } from 'react';
import {
  Badge,
  Checkbox,
  EmptyState,
  ErrorState,
  LoadingState,
  SearchInput,
  SectionCard,
} from '@/components/ui';
import { formatBps, formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import type { CatalogData, Pricing } from '../../api';
import { formatDuration } from '../../model';

export interface ServicesSectionProps {
  catalog: {
    data: CatalogData | undefined;
    isPending: boolean;
    isError: boolean;
    error: unknown;
    refetch: () => unknown;
  };
  selected: string[];
  onToggle: (serviceId: string) => void;
  pricing: {
    data: Pricing | undefined;
    isFetching: boolean;
    isError: boolean;
    error: unknown;
    refetch: () => unknown;
  };
  canPrice: boolean;
  applyMemberDiscount: boolean;
  onApplyMemberDiscount: (value: boolean) => void;
}

export function ServicesSection({
  catalog,
  selected,
  onToggle,
  pricing,
  canPrice,
  applyMemberDiscount,
  onApplyMemberDiscount,
}: ServicesSectionProps) {
  const { currency } = useShop();
  const [search, setSearch] = useState('');
  const money = (cents: number | null) => formatCents(cents, { currency });
  const q = search.trim().toLowerCase();
  const services = catalog.data?.services ?? [];
  const categories = catalog.data?.categories ?? [];
  const visible = services.filter((s) => !q || s.name.toLowerCase().includes(q));
  const groups = [
    ...categories.map((c) => ({ id: c.id, name: c.name })),
    { id: null, name: 'Other' },
  ]
    .map((g) => ({ ...g, services: visible.filter((s) => s.category_id === g.id) }))
    .filter((g) => g.services.length > 0);

  const lines = pricing.data?.lines ?? [];
  const suggested = pricing.data?.suggested_discount_value ?? 0;

  return (
    <SectionCard
      title="Services"
      description="Prices come from your catalog for the vehicle size, including memberships."
    >
      <div className="flex flex-col gap-4">
        <SearchInput label="Search services" value={search} onChange={setSearch} debounceMs={0} />
        {catalog.isPending ? (
          <LoadingState label="Loading catalog…" />
        ) : catalog.isError ? (
          <ErrorState compact error={catalog.error} onRetry={() => void catalog.refetch()} />
        ) : groups.length === 0 ? (
          <EmptyState
            compact
            title={services.length === 0 ? 'Your catalog is empty' : 'No services match'}
            description={services.length === 0 ? 'Add services in the catalog first.' : undefined}
          />
        ) : (
          <div className="flex max-h-96 flex-col gap-4 overflow-y-auto pr-1">
            {groups.map((group) => (
              <fieldset key={group.id ?? 'other'}>
                <legend className="text-muted mb-2 text-xs font-semibold tracking-wide uppercase">
                  {group.name}
                </legend>
                <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
                  {group.services.map((s) => (
                    <Checkbox
                      key={s.id}
                      label={s.name}
                      description={`${s.kind === 'addon' ? 'Add-on · ' : s.kind === 'package' ? 'Package · ' : ''}${formatDuration(s.duration_minutes)}`}
                      checked={selected.includes(s.id)}
                      onChange={() => onToggle(s.id)}
                    />
                  ))}
                </div>
              </fieldset>
            ))}
          </div>
        )}

        {selected.length > 0 && (
          <div className="border-line flex flex-col gap-2 border-t pt-4" aria-live="polite">
            <h3 className="text-ink text-sm font-semibold">Selected</h3>
            {!canPrice ? (
              <p className="text-muted text-sm">
                Choose a customer and vehicle size to see prices.
              </p>
            ) : pricing.isError ? (
              <ErrorState compact error={pricing.error} onRetry={() => void pricing.refetch()} />
            ) : !pricing.data ? (
              <LoadingState label="Pricing…" />
            ) : (
              <>
                <ul className="flex flex-col gap-1.5 text-sm">
                  {lines.map((line) => (
                    <li key={line.service_id} className="flex flex-wrap justify-between gap-2">
                      <span>
                        {line.name}
                        {line.membership_included && (
                          <Badge tone="success" className="ml-2">
                            Membership
                          </Badge>
                        )}
                      </span>
                      <span className="tabular-nums">
                        {line.unit_price_cents === null ? (
                          <span className="text-warning-ink">No price for this size</span>
                        ) : (
                          money(line.unit_price_cents)
                        )}
                      </span>
                    </li>
                  ))}
                </ul>
                {suggested > 0 && (
                  <Checkbox
                    label={`Apply member discount (${formatBps(suggested)})`}
                    description={pricing.data.memberships?.map((m) => m.plan_name).join(', ')}
                    checked={applyMemberDiscount}
                    onChange={(e) => onApplyMemberDiscount(e.target.checked)}
                  />
                )}
                {pricing.data.totals && (
                  <p className="text-muted text-sm">
                    Estimated total{' '}
                    <span className="text-ink font-semibold tabular-nums">
                      {money(pricing.data.totals.total_cents)}
                    </span>{' '}
                    incl. tax{suggested > 0 ? ' with the member discount' : ''} — final totals are
                    calculated when the job is saved.
                  </p>
                )}
                {pricing.isFetching && <p className="text-muted text-xs">Updating prices…</p>}
              </>
            )}
          </div>
        )}
      </div>
    </SectionCard>
  );
}
