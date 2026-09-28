import { useMemo, useState } from 'react';
import { Badge, Checkbox, SearchInput } from '@/components/ui';
import type { ServiceOption } from '../data/pickers';

const KIND_LABELS: Record<ServiceOption['kind'], string> = {
  service: 'Service',
  package: 'Package',
  addon: 'Add-on',
  product: 'Product',
};

export interface ServiceChecklistProps {
  legend: string;
  services: readonly ServiceOption[];
  value: readonly string[];
  onChange: (next: string[]) => void;
  /** Leave products out (they can't be booked). */
  excludeProducts?: boolean;
  /** Mark services hidden from the public booking page. */
  showBookable?: boolean;
  error?: string | undefined;
  disabled?: boolean;
  max?: number;
}

/** Searchable checkbox list of catalog services (booking links, coupon restrictions). */
export function ServiceChecklist({
  legend,
  services,
  value,
  onChange,
  excludeProducts = false,
  showBookable = false,
  error,
  disabled = false,
  max,
}: ServiceChecklistProps) {
  const [search, setSearch] = useState('');
  const selected = useMemo(() => new Set(value), [value]);
  const list = useMemo(() => {
    const term = search.trim().toLowerCase();
    return services.filter(
      (s) =>
        (!excludeProducts || s.kind !== 'product') &&
        (term === '' || s.name.toLowerCase().includes(term)),
    );
  }, [services, search, excludeProducts]);
  const errorId = `${legend.replace(/\W+/g, '-').toLowerCase()}-error`;

  return (
    <fieldset
      className="flex min-w-0 flex-col gap-2"
      disabled={disabled}
      aria-describedby={error ? errorId : undefined}
    >
      <legend className="text-ink mb-1 text-sm font-medium">
        {legend}
        <span className="text-muted ml-2 text-xs font-normal">
          {value.length} selected{max ? ` (max ${max})` : ''}
        </span>
      </legend>
      <SearchInput
        label={`Search ${legend.toLowerCase()}`}
        value={search}
        onChange={setSearch}
        debounceMs={0}
        placeholder="Search services"
      />
      <div className="border-line rounded-control max-h-64 overflow-y-auto border p-2">
        {list.length === 0 ? (
          <p className="text-muted px-1 py-2 text-sm">No services match.</p>
        ) : (
          <ul className="flex flex-col gap-2">
            {list.map((s) => (
              <li key={s.id} className="flex items-center justify-between gap-2">
                <Checkbox
                  label={s.name}
                  checked={selected.has(s.id)}
                  disabled={!selected.has(s.id) && max !== undefined && value.length >= max}
                  onChange={(event) =>
                    onChange(
                      event.target.checked ? [...value, s.id] : value.filter((id) => id !== s.id),
                    )
                  }
                />
                <span className="flex shrink-0 gap-1">
                  <Badge tone="neutral">{KIND_LABELS[s.kind]}</Badge>
                  {!s.active && <Badge tone="warning">Off</Badge>}
                  {showBookable && s.active && !s.online_bookable && (
                    <Badge tone="info">Hidden online</Badge>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
      {error && (
        <p id={errorId} role="alert" className="text-danger-ink text-xs font-medium">
          {error}
        </p>
      )}
    </fieldset>
  );
}
