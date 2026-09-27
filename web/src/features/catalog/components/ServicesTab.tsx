import { Package, Plus } from 'lucide-react';
import { useMemo, useState } from 'react';
import {
  Badge,
  Button,
  EmptyState,
  ErrorState,
  LoadingState,
  SearchInput,
  Select,
  SectionCard,
  Switch,
  Table,
  type Column,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useBasePrices, useCategories, useServices } from '../api';
import {
  formatDuration,
  isServiceKind,
  KIND_LABELS,
  KIND_PLURALS,
  SERVICE_KINDS,
  type ServiceKind,
  type ServiceRow,
} from '../model';

export interface ServicesTabProps {
  canManage: boolean;
  onNew: () => void;
}

type KindFilter = ServiceKind | 'all';

export function ServicesTab({ canManage, onNew }: ServicesTabProps) {
  const { currency } = useShop();
  const services = useServices();
  const categories = useCategories();
  const prices = useBasePrices();
  const [query, setQuery] = useState('');
  const [kind, setKind] = useState<KindFilter>('all');
  const [showArchived, setShowArchived] = useState(false);

  const categoryName = useMemo(
    () => new Map((categories.data ?? []).map((c) => [c.id, c.name])),
    [categories.data],
  );

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    return (services.data ?? []).filter(
      (s) =>
        (showArchived || s.archived_at === null) &&
        (kind === 'all' || s.kind === kind) &&
        (q === '' ||
          s.name.toLowerCase().includes(q) ||
          (s.description ?? '').toLowerCase().includes(q)),
    );
  }, [services.data, query, kind, showArchived]);

  const columns: Column<ServiceRow>[] = [
    {
      key: 'name',
      header: 'Name',
      primary: true,
      cell: (s) => (
        <span className="flex flex-col">
          <span className="font-medium">{s.name}</span>
          {s.description && (
            <span className="text-muted line-clamp-1 text-xs font-normal">{s.description}</span>
          )}
        </span>
      ),
    },
    { key: 'kind', header: 'Type', cell: (s) => KIND_LABELS[s.kind] },
    {
      key: 'category',
      header: 'Category',
      cell: (s) => {
        if (!s.category_id) return '—';
        if (categories.isPending) return <span aria-label="Loading">…</span>;
        if (categories.error) return <span className="text-subtle">Unavailable</span>;
        return categoryName.get(s.category_id) ?? '—';
      },
    },
    {
      key: 'duration',
      header: 'Time',
      align: 'right',
      cell: (s) => <span className="tabular">{formatDuration(s.duration_minutes)}</span>,
    },
    {
      key: 'price',
      header: 'Base price',
      align: 'right',
      cell: (s) => {
        if (prices.isPending) return <span aria-label="Loading">…</span>;
        // Never claim "Not set" when the prices simply failed to load.
        if (prices.error) return <span className="text-subtle">Unavailable</span>;
        const cents = prices.data?.get(s.id);
        return cents === undefined ? (
          <span className="text-subtle">Not set</span>
        ) : (
          <span className="tabular">{formatCents(cents, { currency })}</span>
        );
      },
    },
    {
      key: 'status',
      header: 'Status',
      cell: (s) => (
        <span className="flex flex-wrap justify-end gap-1 md:justify-start">
          {s.archived_at ? (
            <Badge tone="neutral">Archived</Badge>
          ) : s.active ? (
            <Badge tone="success" dot>
              Active
            </Badge>
          ) : (
            <Badge tone="neutral" dot>
              Inactive
            </Badge>
          )}
          {s.online_bookable && !s.archived_at && <Badge tone="info">Online</Badge>}
        </span>
      ),
    },
  ];

  let body;
  if (services.isPending) body = <LoadingState label="Loading catalog…" variant="rows" />;
  else if (services.error)
    body = (
      <ErrorState
        error={services.error}
        title="Couldn’t load the catalog"
        onRetry={() => void services.refetch()}
        retrying={services.isRefetching}
      />
    );
  else if ((services.data ?? []).length === 0)
    body = (
      <EmptyState
        icon={<Package aria-hidden="true" />}
        title="No services yet"
        description={
          canManage
            ? 'Add the services, packages, add-ons and products you sell, then set prices by vehicle size.'
            : 'Your shop hasn’t added any services yet.'
        }
        action={
          canManage ? (
            <Button leadingIcon={<Plus />} onClick={onNew}>
              New item
            </Button>
          ) : undefined
        }
      />
    );
  else if (rows.length === 0)
    body = (
      <EmptyState
        compact
        title="Nothing matches"
        description="Try another search, type or show archived items."
      />
    );
  else {
    const detailsError = prices.error ?? categories.error;
    body = (
      <>
        {detailsError && (
          <div className="border-line border-b">
            <ErrorState
              compact
              error={detailsError}
              title={prices.error ? 'Couldn’t load base prices' : 'Couldn’t load category names'}
              onRetry={() => {
                if (prices.error) void prices.refetch();
                if (categories.error) void categories.refetch();
              }}
              retrying={prices.isRefetching || categories.isRefetching}
            />
          </div>
        )}
        <Table
          caption="Catalog items"
          columns={columns}
          rows={rows}
          getRowId={(s) => s.id}
          rowHref={(s) => `/app/catalog/services/${s.id}`}
        />
      </>
    );
  }

  return (
    <SectionCard
      title="Services & products"
      flush
      actions={
        <div className="flex w-full flex-col gap-2 sm:w-auto sm:flex-row sm:items-center">
          <SearchInput
            value={query}
            onChange={setQuery}
            label="Search catalog"
            placeholder="Search…"
            className="sm:w-52"
          />
          <Select
            aria-label="Type"
            value={kind}
            onChange={(e) => setKind(isServiceKind(e.target.value) ? e.target.value : 'all')}
            options={[
              { value: 'all', label: 'All types' },
              ...SERVICE_KINDS.map((k) => ({ value: k, label: KIND_PLURALS[k] })),
            ]}
          />
          <Switch
            label="Show archived"
            checked={showArchived}
            onCheckedChange={setShowArchived}
            className="sm:gap-2"
          />
        </div>
      }
    >
      {body}
    </SectionCard>
  );
}
