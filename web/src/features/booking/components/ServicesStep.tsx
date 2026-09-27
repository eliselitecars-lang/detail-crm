import { Clock } from 'lucide-react';
import { useId, useState } from 'react';
import { cn } from '@/lib/cn';
import { formatCents } from '@/lib/money';
import { formatDuration } from '@/features/public-docs/shared/format';
import type { BookingCatalog, CatalogAddon, CatalogService } from '../api';
import { eligibleAddons, groupServices, priceFor } from '../model';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { StepFrame } from './StepFrame';

const MAX_ITEMS = 20;

export function ServicesStep({
  catalog,
  currency,
  categoryId,
  serviceIds,
  addonIds,
  onChange,
  onBack,
  onContinue,
  notice = null,
}: {
  catalog: BookingCatalog;
  currency: string;
  categoryId: string | null;
  serviceIds: string[];
  addonIds: string[];
  onChange: (next: { serviceIds: string[]; addonIds: string[] }) => void;
  onBack: () => void;
  onContinue: () => void;
  notice?: string | null;
}) {
  const [error, setError] = useState<string | null>(null);
  const groups = groupServices(catalog);
  const addons = eligibleAddons(catalog, serviceIds, categoryId);
  const categoryName = catalog.vehicle_categories.find((c) => c.id === categoryId)?.name ?? null;

  const toggleService = (id: string, on: boolean) => {
    const nextServices = on ? [...serviceIds, id] : serviceIds.filter((s) => s !== id);
    const allowed = new Set(eligibleAddons(catalog, nextServices, categoryId).map((a) => a.id));
    onChange({ serviceIds: nextServices, addonIds: addonIds.filter((a) => allowed.has(a)) });
    if (nextServices.length > 0) setError(null);
  };
  const toggleAddon = (id: string, on: boolean) => {
    onChange({ serviceIds, addonIds: on ? [...addonIds, id] : addonIds.filter((a) => a !== id) });
  };

  const next = () => {
    if (serviceIds.length === 0) {
      setError('Choose at least one service.');
      return;
    }
    if (serviceIds.length > MAX_ITEMS || addonIds.length > MAX_ITEMS) {
      setError(`Choose up to ${MAX_ITEMS} services and ${MAX_ITEMS} add-ons.`);
      return;
    }
    onContinue();
  };

  return (
    <StepFrame
      title="Choose your services"
      description={
        categoryName
          ? `Prices shown for: ${categoryName}. Your final total is confirmed when you book.`
          : 'Your final total is confirmed when you book.'
      }
      onBack={onBack}
      onContinue={next}
    >
      {notice && <Banner tone="warning" title={notice} />}
      {error && (
        <p role="alert" className="text-danger-ink text-sm font-medium">
          {error}
        </p>
      )}
      {groups.map((group) => (
        <fieldset key={group.id ?? 'other'} className="flex flex-col gap-2">
          <legend className={cn('text-ink mb-1 text-sm font-semibold', !group.name && 'sr-only')}>
            {group.name ?? 'Services'}
          </legend>
          {group.services.map((service) => (
            <ItemCard
              key={service.id}
              item={service}
              currency={currency}
              categoryId={categoryId}
              categoryName={categoryName}
              checked={serviceIds.includes(service.id)}
              onToggle={(on) => toggleService(service.id, on)}
            />
          ))}
        </fieldset>
      ))}
      {serviceIds.length > 0 && addons.length > 0 && (
        <fieldset className="flex flex-col gap-2">
          <legend className="text-ink mb-1 text-sm font-semibold">Add-ons</legend>
          {addons.map((addon) => (
            <ItemCard
              key={addon.id}
              item={addon}
              currency={currency}
              categoryId={categoryId}
              categoryName={categoryName}
              checked={addonIds.includes(addon.id)}
              onToggle={(on) => toggleAddon(addon.id, on)}
            />
          ))}
        </fieldset>
      )}
    </StepFrame>
  );
}

function ItemCard({
  item,
  currency,
  categoryId,
  categoryName,
  checked,
  onToggle,
}: {
  item: CatalogService | CatalogAddon;
  currency: string;
  categoryId: string | null;
  categoryName: string | null;
  checked: boolean;
  onToggle: (on: boolean) => void;
}) {
  const id = useId();
  const price = priceFor(item, categoryId);
  const unavailable = price === null;
  const includes = 'includes' in item ? item.includes : [];
  const duration = formatDuration(price?.durationMinutes ?? item.duration_minutes);
  return (
    <label
      htmlFor={id}
      className={cn(
        'rounded-card bg-surface flex cursor-pointer items-start gap-3 border p-3 transition-colors sm:p-4',
        'has-[:focus-visible]:outline-primary has-[:focus-visible]:outline-2',
        checked ? 'border-primary bg-primary-soft' : 'border-line hover:border-line-strong',
        unavailable && 'cursor-not-allowed opacity-60',
      )}
    >
      <input
        id={id}
        type="checkbox"
        checked={checked}
        disabled={unavailable}
        onChange={(event) => onToggle(event.target.checked)}
        className="mt-1 size-4 shrink-0 accent-[var(--dc-primary)]"
      />
      <span className="flex min-w-0 flex-1 flex-col gap-1">
        <span className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <span className="text-ink text-sm font-semibold">{item.name}</span>
          <span className="text-ink text-sm font-semibold tabular-nums">
            {unavailable
              ? `Not available${categoryName ? ` for ${categoryName}` : ''}`
              : formatCents(price.priceCents, { currency })}
          </span>
        </span>
        {item.description && (
          <span className="text-muted line-clamp-3 text-xs break-words whitespace-pre-line">
            {item.description}
          </span>
        )}
        {includes.length > 0 && (
          <span className="text-muted text-xs">Includes: {includes.join(', ')}</span>
        )}
        {duration && (
          <span className="text-muted inline-flex items-center gap-1 text-xs">
            <Clock className="size-3.5" aria-hidden="true" />
            {duration}
          </span>
        )}
      </span>
    </label>
  );
}
