import { Plus, Users } from 'lucide-react';
import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import {
  Badge,
  Button,
  Card,
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  Pagination,
  SearchInput,
  Select,
  Table,
  type Column,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { formatDate } from '@/lib/dates';
import { formatPhone } from '@/lib/phone';
import {
  useCustomerList,
  useKnownTags,
  type ArchivedFilter,
  type CustomerListFilters,
  type CustomerSortKey,
} from './api';
import { CustomerFormDialog } from './components/CustomerFormDialog';
import { parseListParams, toListParams } from './listParams';
import { customerName, isLifecycle, LIFECYCLE_LABELS, LIFECYCLES, type CustomerRow } from './model';

type ListRow = Pick<
  CustomerRow,
  | 'id'
  | 'first_name'
  | 'last_name'
  | 'company'
  | 'email'
  | 'phone'
  | 'tags'
  | 'lifecycle'
  | 'archived_at'
  | 'created_at'
>;

type ColumnKey = CustomerSortKey | 'phone' | 'email' | 'tags' | 'lifecycle';

function isArchivedFilter(value: string): value is ArchivedFilter {
  return value === 'active' || value === 'archived' || value === 'all';
}

export default function CustomersPage() {
  const { shopId, timezone } = useShop();
  const canManage = useCan('customers.manage');
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const filters = parseListParams(params);
  const [creating, setCreating] = useState(false);

  const list = useCustomerList(shopId, filters);
  const tags = useKnownTags(shopId);

  const update = (patch: Partial<CustomerListFilters>) => {
    setParams(toListParams({ ...filters, page: 1, ...patch }), { replace: true });
  };

  // A page past the end (stale link, or back after archiving shrank the
  // list) is not "no customers": step back to the last page that has rows.
  const lastPage = list.data ? Math.max(1, Math.ceil(list.data.total / filters.pageSize)) : 1;
  const pastEnd =
    list.isSuccess &&
    !list.isPlaceholderData &&
    list.data.rows.length === 0 &&
    filters.page > 1 &&
    filters.page > lastPage;
  const clampTo = pastEnd ? toListParams({ ...filters, page: lastPage }).toString() : null;
  useEffect(() => {
    if (clampTo !== null) setParams(new URLSearchParams(clampTo), { replace: true });
  }, [clampTo, setParams]);

  const filtered =
    filters.search.trim() !== '' ||
    filters.tag !== null ||
    filters.lifecycle !== null ||
    filters.archived !== 'active';

  const columns: Column<ListRow, ColumnKey>[] = [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      primary: true,
      cell: (c) => (
        <span className="inline-flex min-w-0 flex-col">
          <span className="break-words">{customerName(c)}</span>
          {c.company && (c.first_name || c.last_name) && (
            <span className="text-muted text-xs font-normal">{c.company}</span>
          )}
        </span>
      ),
    },
    {
      key: 'phone',
      header: 'Phone',
      cell: (c) =>
        c.phone ? <span className="tabular whitespace-nowrap">{formatPhone(c.phone)}</span> : '—',
    },
    {
      key: 'email',
      header: 'Email',
      hideOnMobile: true,
      cell: (c) => <span className="break-all">{c.email ?? '—'}</span>,
    },
    {
      key: 'tags',
      header: 'Tags',
      hideOnMobile: true,
      cell: (c) =>
        c.tags.length === 0 ? (
          <span className="text-subtle">—</span>
        ) : (
          <span className="flex flex-wrap gap-1">
            {c.tags.slice(0, 3).map((t) => (
              <Badge key={t}>{t}</Badge>
            ))}
            {c.tags.length > 3 && <Badge>+{c.tags.length - 3}</Badge>}
          </span>
        ),
    },
    {
      key: 'lifecycle',
      header: 'Status',
      cell: (c) => (
        <span className="inline-flex flex-wrap justify-end gap-1 md:justify-start">
          <Badge tone={c.lifecycle === 'lead' ? 'warning' : 'neutral'}>
            {LIFECYCLE_LABELS[c.lifecycle]}
          </Badge>
          {c.archived_at && <Badge tone="neutral">Archived</Badge>}
        </span>
      ),
    },
    {
      key: 'created_at',
      header: 'Added',
      sortable: true,
      align: 'right',
      cell: (c) => <span className="whitespace-nowrap">{formatDate(c.created_at, timezone)}</span>,
    },
  ];

  const tagOptions = [...new Set([...(tags.data ?? []), ...(filters.tag ? [filters.tag] : [])])];

  return (
    <>
      <PageHeader
        title="Customers"
        description={
          canManage
            ? 'Everyone you work for, with their vehicles and history.'
            : 'Customers on jobs assigned to you.'
        }
        actions={
          canManage && (
            <Button
              leadingIcon={<Plus className="size-4" aria-hidden="true" />}
              onClick={() => setCreating(true)}
            >
              New customer
            </Button>
          )
        }
      />

      <Card className="overflow-hidden">
        <div className="border-line flex flex-col gap-3 border-b p-3 sm:p-4 lg:flex-row lg:items-center">
          <SearchInput
            className="lg:max-w-sm lg:flex-1"
            label="Search customers"
            placeholder="Name, email, phone or company"
            value={filters.search}
            onChange={(search) => update({ search })}
          />
          <div className="grid grid-cols-1 gap-2 min-[480px]:grid-cols-3 lg:flex lg:flex-none">
            <Select
              aria-label="Filter by tag"
              value={filters.tag ?? ''}
              onChange={(e) => update({ tag: e.target.value || null })}
              placeholder="All tags"
              options={tagOptions.map((t) => ({ value: t, label: t }))}
            />
            <Select
              aria-label="Filter by lifecycle"
              value={filters.lifecycle ?? ''}
              onChange={(e) =>
                update({ lifecycle: isLifecycle(e.target.value) ? e.target.value : null })
              }
              placeholder="Leads & customers"
              options={LIFECYCLES.map((v) => ({ value: v, label: `${LIFECYCLE_LABELS[v]}s` }))}
            />
            <Select
              aria-label="Archived customers"
              value={filters.archived}
              onChange={(e) => {
                if (isArchivedFilter(e.target.value)) update({ archived: e.target.value });
              }}
              options={[
                { value: 'active', label: 'Active' },
                { value: 'archived', label: 'Archived' },
                { value: 'all', label: 'Active & archived' },
              ]}
            />
          </div>
        </div>

        {list.isPending || pastEnd ? (
          <LoadingState variant="rows" rows={6} label="Loading customers…" />
        ) : list.isError ? (
          <ErrorState
            error={list.error}
            onRetry={() => void list.refetch()}
            retrying={list.isRefetching}
          />
        ) : list.data.rows.length === 0 ? (
          filtered ? (
            <EmptyState
              icon={<Users aria-hidden="true" />}
              title="No customers match"
              description="Try a different search or clear the filters."
              action={
                <Button variant="secondary" onClick={() => setParams(new URLSearchParams())}>
                  Clear filters
                </Button>
              }
            />
          ) : (
            <EmptyState
              icon={<Users aria-hidden="true" />}
              title={canManage ? 'No customers yet' : 'No customers to show'}
              description={
                canManage
                  ? 'Add your first customer — people who book online show up here too.'
                  : 'Customers appear here when you’re assigned to one of their jobs.'
              }
              action={
                canManage && <Button onClick={() => setCreating(true)}>Add a customer</Button>
              }
            />
          )
        ) : (
          <div aria-busy={list.isPlaceholderData}>
            <Table
              caption="Customers"
              columns={columns}
              rows={list.data.rows}
              getRowId={(c) => c.id}
              rowHref={(c) => `/app/customers/${c.id}`}
              sort={filters.sort}
              extraSortOptions={[{ key: 'updated_at', label: 'Last updated' }]}
              onSortChange={(sort) => {
                if (sort.key === 'name' || sort.key === 'created_at' || sort.key === 'updated_at') {
                  update({ sort: { key: sort.key, direction: sort.direction } });
                }
              }}
            />
            <Pagination
              className="border-line border-t"
              page={filters.page}
              pageSize={filters.pageSize}
              total={list.data.total}
              onPageChange={(page) => setParams(toListParams({ ...filters, page }))}
            />
          </div>
        )}
      </Card>

      {creating && (
        <CustomerFormDialog
          open
          onClose={() => setCreating(false)}
          onSaved={(id) => void navigate(`/app/customers/${id}`)}
        />
      )}
    </>
  );
}
