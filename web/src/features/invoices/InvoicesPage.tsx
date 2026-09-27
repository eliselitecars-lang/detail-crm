import { Plus, Receipt } from 'lucide-react';
import { Link, useSearchParams } from 'react-router';
import {
  Badge,
  buttonClasses,
  Card,
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  Pagination,
  SearchInput,
  StatusBadge,
  Table,
  Tabs,
  type Column,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import { customerName } from '@/features/quotes/shared/format';
import {
  INVOICE_PAGE_SIZE,
  isInvoiceOverdue,
  useInvoices,
  type InvoiceListRow,
  type InvoiceStatusFilter,
} from './api';

const STATUS_TABS: { value: InvoiceStatusFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'draft', label: 'Drafts' },
  { value: 'open', label: 'Unpaid' },
  { value: 'overdue', label: 'Overdue' },
  { value: 'paid', label: 'Paid' },
  { value: 'void', label: 'Void' },
];

function isStatusFilter(value: string | null): value is InvoiceStatusFilter {
  return STATUS_TABS.some((tab) => tab.value === value);
}

export default function InvoicesPage() {
  const { timezone, currency } = useShop();
  const canManage = useCan('invoices.manage');
  const [params, setParams] = useSearchParams();
  const rawStatus = params.get('status');
  const status: InvoiceStatusFilter = isStatusFilter(rawStatus) ? rawStatus : 'all';
  const search = params.get('q') ?? '';
  const page = Math.max(1, Number(params.get('page') ?? '1') || 1);

  const update = (next: { status?: InvoiceStatusFilter; q?: string; page?: number }) => {
    const merged = new URLSearchParams(params);
    if (next.status !== undefined) merged.set('status', next.status);
    if (next.q !== undefined) {
      if (next.q) merged.set('q', next.q);
      else merged.delete('q');
    }
    merged.set('page', String(next.page ?? 1));
    if (merged.get('status') === 'all') merged.delete('status');
    if (merged.get('page') === '1') merged.delete('page');
    setParams(merged, { replace: true });
  };

  const invoices = useInvoices({ status, search, page });
  const money = (cents: number) => formatCents(cents, { currency });

  const columns: Column<InvoiceListRow>[] = [
    { key: 'number', header: 'Invoice', primary: true, cell: (i) => `Invoice #${i.number}` },
    { key: 'customer', header: 'Customer', cell: (i) => customerName(i.customer) },
    {
      key: 'status',
      header: 'Status',
      cell: (i) => (
        <span className="inline-flex flex-wrap items-center justify-end gap-1.5 md:justify-start">
          <StatusBadge kind="invoice" status={i.status} />
          {isInvoiceOverdue(i) && <Badge tone="danger">Overdue</Badge>}
        </span>
      ),
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
      hideOnMobile: true,
      cell: (i) => <span className="tabular-nums">{money(i.total_cents)}</span>,
    },
    {
      key: 'balance',
      header: 'Balance',
      align: 'right',
      cell: (i) =>
        i.status === 'void' ? (
          '—'
        ) : i.balance_cents > 0 ? (
          <Badge tone="money">{money(i.balance_cents)}</Badge>
        ) : (
          <span className="tabular-nums">{money(i.balance_cents)}</span>
        ),
    },
  ];

  const filtered = status !== 'all' || search.trim() !== '';

  return (
    <>
      <PageHeader
        title="Invoices"
        description="Invoices, balances and payment links."
        actions={
          canManage ? (
            <Link to="/app/invoices/new" className={buttonClasses({ variant: 'primary' })}>
              <Plus className="size-4" aria-hidden="true" />
              New invoice
            </Link>
          ) : undefined
        }
      />
      <Card>
        <div className="flex flex-col gap-3 p-4">
          <Tabs
            label="Invoice status"
            items={STATUS_TABS}
            value={status}
            onChange={(value) => update({ status: value })}
          />
          <SearchInput
            label="Search invoices"
            placeholder="Search by invoice number or customer…"
            value={search}
            onChange={(q) => update({ q })}
          />
        </div>
        {invoices.isPending ? (
          <LoadingState variant="rows" rows={6} label="Loading invoices…" />
        ) : invoices.isError ? (
          <ErrorState
            error={invoices.error}
            onRetry={() => void invoices.refetch()}
            retrying={invoices.isRefetching}
          />
        ) : invoices.data.rows.length === 0 ? (
          <EmptyState
            icon={<Receipt aria-hidden="true" />}
            title={filtered ? 'No invoices match these filters' : 'No invoices yet'}
            description={
              filtered
                ? 'Try another status or search.'
                : 'Invoices are created from completed jobs, or you can create one here.'
            }
            action={
              !filtered && canManage ? (
                <Link to="/app/invoices/new" className={buttonClasses({ variant: 'primary' })}>
                  New invoice
                </Link>
              ) : undefined
            }
          />
        ) : (
          <>
            <Table
              caption="Invoices"
              columns={columns}
              rows={invoices.data.rows}
              getRowId={(i) => i.id}
              rowHref={(i) => `/app/invoices/${i.id}`}
            />
            <Pagination
              className="border-line border-t px-4 py-3"
              page={page}
              pageSize={INVOICE_PAGE_SIZE}
              total={invoices.data.total}
              onPageChange={(next) => update({ page: next })}
            />
          </>
        )}
      </Card>
    </>
  );
}
