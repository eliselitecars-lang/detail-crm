/**
 * Read-only history lists on the customer page. Each links to the owning
 * feature's detail page; money shown is the server's stored values.
 */
import { BadgeCheck, Briefcase, FileText, Receipt } from 'lucide-react';
import type { ReactNode } from 'react';
import { Link } from 'react-router';
import {
  Card,
  EmptyState,
  ErrorState,
  LoadingState,
  StatusBadge,
  Table,
  type Column,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { formatDate, formatDateTime, formatLocalDate } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import {
  useCustomerInvoices,
  useCustomerJobs,
  useCustomerMemberships,
  useCustomerQuotes,
  useCustomerVehicles,
} from '../api';
import { vehicleLabel } from '../model';

interface QueryLike<T> {
  isPending: boolean;
  isError: boolean;
  error: unknown;
  data: T | undefined;
  refetch: () => Promise<unknown>;
}

function ListState<T>({
  query,
  label,
  empty,
  children,
}: {
  query: QueryLike<T[]>;
  label: string;
  empty: ReactNode;
  children: (rows: T[]) => ReactNode;
}) {
  return (
    <Card className="overflow-hidden">
      {query.isPending ? (
        <LoadingState variant="rows" rows={4} label={`Loading ${label}…`} />
      ) : query.isError || !query.data ? (
        <ErrorState error={query.error} onRetry={() => void query.refetch()} />
      ) : query.data.length === 0 ? (
        empty
      ) : (
        children(query.data)
      )}
    </Card>
  );
}

/** vehicle_id → "2021 Toyota Camry" from the customer's vehicles (incl. archived). */
function useVehicleLabels(customerId: string) {
  const { shopId } = useShop();
  const vehicles = useCustomerVehicles(shopId, customerId, true);
  return (id: string | null) => {
    if (!id) return '—';
    const v = vehicles.data?.find((x) => x.id === id);
    return v ? vehicleLabel(v) : '—';
  };
}

export function JobsTab({ customerId }: { customerId: string }) {
  const { shopId, timezone, currency } = useShop();
  const showMoney = useCan('invoices.view');
  const canCreate = useCan('jobs.manage');
  const jobs = useCustomerJobs(shopId, customerId);
  const vehicle = useVehicleLabels(customerId);
  type JobRow = NonNullable<typeof jobs.data>[number];

  const columns: Column<JobRow>[] = [
    { key: 'number', header: 'Job', primary: true, cell: (j) => `#${j.number}` },
    { key: 'status', header: 'Status', cell: (j) => <StatusBadge kind="job" status={j.status} /> },
    {
      key: 'when',
      header: 'Scheduled',
      cell: (j) =>
        j.scheduled_start ? formatDateTime(j.scheduled_start, timezone) : 'Not scheduled',
    },
    { key: 'vehicle', header: 'Vehicle', cell: (j) => vehicle(j.vehicle_id) },
    ...(showMoney
      ? [
          {
            key: 'total',
            header: 'Total',
            align: 'right' as const,
            cell: (j: JobRow) => (
              <span className="tabular">{formatCents(j.total_cents, { currency })}</span>
            ),
          },
        ]
      : []),
  ];

  return (
    <ListState
      query={jobs}
      label="jobs"
      empty={
        <EmptyState
          compact
          icon={<Briefcase aria-hidden="true" />}
          title="No jobs yet"
          action={
            canCreate && (
              <Link
                to={`/app/jobs/new?customerId=${customerId}`}
                className="text-primary-ink text-sm font-medium hover:underline"
              >
                Create a job
              </Link>
            )
          }
        />
      }
    >
      {(rows) => (
        <Table
          caption="Jobs"
          columns={columns}
          rows={rows}
          getRowId={(j) => j.id}
          rowHref={(j) => `/app/jobs/${j.id}`}
        />
      )}
    </ListState>
  );
}

export function QuotesTab({ customerId }: { customerId: string }) {
  const { shopId, timezone, currency } = useShop();
  const canView = useCan('quotes.view');
  const quotes = useCustomerQuotes(shopId, customerId, canView);
  const vehicle = useVehicleLabels(customerId);
  type QuoteRow = NonNullable<typeof quotes.data>[number];

  const columns: Column<QuoteRow>[] = [
    { key: 'number', header: 'Quote', primary: true, cell: (q) => `#${q.number}` },
    {
      key: 'status',
      header: 'Status',
      cell: (q) => <StatusBadge kind="quote" status={q.status} />,
    },
    {
      key: 'sent',
      header: 'Sent',
      cell: (q) => (q.sent_at ? formatDate(q.sent_at, timezone) : 'Not sent'),
    },
    {
      key: 'valid',
      header: 'Valid until',
      hideOnMobile: true,
      cell: (q) => (q.valid_until ? formatLocalDate(q.valid_until) : '—'),
    },
    { key: 'vehicle', header: 'Vehicle', hideOnMobile: true, cell: (q) => vehicle(q.vehicle_id) },
    {
      key: 'total',
      header: 'Total',
      align: 'right',
      cell: (q) => <span className="tabular">{formatCents(q.total_cents, { currency })}</span>,
    },
  ];

  return (
    <ListState
      query={quotes}
      label="quotes"
      empty={
        <EmptyState
          compact
          icon={<FileText aria-hidden="true" />}
          title="No quotes yet"
          action={
            <Link
              to={`/app/quotes/new?customerId=${customerId}`}
              className="text-primary-ink text-sm font-medium hover:underline"
            >
              Create a quote
            </Link>
          }
        />
      }
    >
      {(rows) => (
        <Table
          caption="Quotes"
          columns={columns}
          rows={rows}
          getRowId={(q) => q.id}
          rowHref={(q) => `/app/quotes/${q.id}`}
        />
      )}
    </ListState>
  );
}

export function InvoicesTab({ customerId }: { customerId: string }) {
  const { shopId, timezone, currency } = useShop();
  const canView = useCan('invoices.view');
  const invoices = useCustomerInvoices(shopId, customerId, canView);
  type InvoiceRow = NonNullable<typeof invoices.data>[number];

  const columns: Column<InvoiceRow>[] = [
    { key: 'number', header: 'Invoice', primary: true, cell: (i) => `#${i.number}` },
    {
      key: 'status',
      header: 'Status',
      cell: (i) => <StatusBadge kind="invoice" status={i.status} />,
    },
    {
      key: 'issued',
      header: 'Issued',
      cell: (i) => (i.issued_at ? formatDate(i.issued_at, timezone) : 'Draft'),
    },
    {
      key: 'due',
      header: 'Due',
      hideOnMobile: true,
      cell: (i) => (i.due_at ? formatDate(i.due_at, timezone) : '—'),
    },
    {
      key: 'total',
      header: 'Total',
      align: 'right',
      cell: (i) => <span className="tabular">{formatCents(i.total_cents, { currency })}</span>,
    },
    {
      key: 'balance',
      header: 'Balance',
      align: 'right',
      cell: (i) => (
        <span
          className={
            i.balance_cents > 0 && i.status !== 'void'
              ? 'tabular text-money-ink font-medium'
              : 'tabular'
          }
        >
          {formatCents(i.balance_cents, { currency })}
        </span>
      ),
    },
  ];

  return (
    <ListState
      query={invoices}
      label="invoices"
      empty={<EmptyState compact icon={<Receipt aria-hidden="true" />} title="No invoices yet" />}
    >
      {(rows) => (
        <Table
          caption="Invoices"
          columns={columns}
          rows={rows}
          getRowId={(i) => i.id}
          rowHref={(i) => `/app/invoices/${i.id}`}
        />
      )}
    </ListState>
  );
}

export function MembershipsTab({ customerId }: { customerId: string }) {
  const { shopId, timezone, currency } = useShop();
  const canView = useCan('memberships.view');
  const memberships = useCustomerMemberships(shopId, customerId, canView);
  const vehicle = useVehicleLabels(customerId);
  type MembershipRow = NonNullable<typeof memberships.data>[number];

  const interval = (m: MembershipRow) => {
    if (!m.plan) return '';
    const unit = m.plan.interval === 'year' ? 'yr' : 'mo';
    return m.plan.interval_count > 1 ? ` / ${m.plan.interval_count} ${unit}` : ` / ${unit}`;
  };

  const columns: Column<MembershipRow>[] = [
    {
      key: 'plan',
      header: 'Plan',
      primary: true,
      cell: (m) => m.plan?.name ?? 'Plan',
    },
    {
      key: 'status',
      header: 'Status',
      cell: (m) => <StatusBadge kind="membership" status={m.status} />,
    },
    { key: 'vehicle', header: 'Vehicle', cell: (m) => vehicle(m.vehicle_id) },
    {
      key: 'price',
      header: 'Price',
      hideOnMobile: true,
      cell: (m) =>
        m.plan ? `${formatCents(m.plan.price_cents, { currency })}${interval(m)}` : '—',
    },
    {
      key: 'renews',
      header: 'Renews',
      align: 'right',
      cell: (m) =>
        m.status === 'cancelled'
          ? '—'
          : m.current_period_end
            ? `${m.cancel_at_period_end ? 'Ends' : 'Renews'} ${formatDate(m.current_period_end, timezone)}`
            : '—',
    },
  ];

  return (
    <ListState
      query={memberships}
      label="memberships"
      empty={
        <EmptyState
          compact
          icon={<BadgeCheck aria-hidden="true" />}
          title="No memberships"
          action={
            <Link
              to={`/app/memberships?customer=${customerId}`}
              className="text-primary-ink text-sm font-medium hover:underline"
            >
              Go to memberships
            </Link>
          }
        />
      }
    >
      {(rows) => (
        <Table caption="Memberships" columns={columns} rows={rows} getRowId={(m) => m.id} />
      )}
    </ListState>
  );
}
