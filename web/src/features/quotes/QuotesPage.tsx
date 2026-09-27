import { FileText, Plus } from 'lucide-react';
import { Link, useSearchParams } from 'react-router';
import {
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
import { formatDate, formatLocalDate, shopToday } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import {
  effectiveQuoteStatus,
  QUOTE_PAGE_SIZE,
  useQuotes,
  type QuoteListRow,
  type QuoteStatusFilter,
} from './api';
import { customerName } from './shared/format';

const STATUS_TABS: { value: QuoteStatusFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'draft', label: 'Drafts' },
  { value: 'sent', label: 'Sent' },
  { value: 'approved', label: 'Approved' },
  { value: 'declined', label: 'Declined' },
  { value: 'expired', label: 'Expired' },
  { value: 'converted', label: 'Converted' },
];

function isStatusFilter(value: string | null): value is QuoteStatusFilter {
  return STATUS_TABS.some((tab) => tab.value === value);
}

export default function QuotesPage() {
  const { timezone, currency } = useShop();
  const canManage = useCan('quotes.manage');
  const [params, setParams] = useSearchParams();
  const rawStatus = params.get('status');
  const status: QuoteStatusFilter = isStatusFilter(rawStatus) ? rawStatus : 'all';
  const search = params.get('q') ?? '';
  const page = Math.max(1, Number(params.get('page') ?? '1') || 1);

  const update = (next: { status?: QuoteStatusFilter; q?: string; page?: number }) => {
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

  const quotes = useQuotes({ status, search, page });
  const today = shopToday(timezone);

  const columns: Column<QuoteListRow>[] = [
    { key: 'number', header: 'Quote', primary: true, cell: (q) => `Quote #${q.number}` },
    { key: 'customer', header: 'Customer', cell: (q) => customerName(q.customer) },
    {
      key: 'status',
      header: 'Status',
      cell: (q) => <StatusBadge kind="quote" status={effectiveQuoteStatus(q, today)} />,
    },
    {
      key: 'valid',
      header: 'Valid until',
      hideOnMobile: true,
      cell: (q) => (q.valid_until ? formatLocalDate(q.valid_until) : 'No expiry'),
    },
    {
      key: 'created',
      header: 'Created',
      hideOnMobile: true,
      cell: (q) => formatDate(q.created_at, timezone),
    },
    {
      key: 'total',
      header: 'Total',
      align: 'right',
      cell: (q) => <span className="tabular-nums">{formatCents(q.total_cents, { currency })}</span>,
    },
  ];

  const filtered = status !== 'all' || search.trim() !== '';

  return (
    <>
      <PageHeader
        title="Quotes"
        description="Estimates customers can review and approve online."
        actions={
          canManage ? (
            <Link to="/app/quotes/new" className={buttonClasses({ variant: 'primary' })}>
              <Plus className="size-4" aria-hidden="true" />
              New quote
            </Link>
          ) : undefined
        }
      />
      <Card>
        <div className="flex flex-col gap-3 p-4">
          <Tabs
            label="Quote status"
            items={STATUS_TABS}
            value={status}
            onChange={(value) => update({ status: value })}
          />
          <SearchInput
            label="Search quotes"
            placeholder="Search by quote number or customer…"
            value={search}
            onChange={(q) => update({ q })}
          />
        </div>
        {quotes.isPending ? (
          <LoadingState variant="rows" rows={6} label="Loading quotes…" />
        ) : quotes.isError ? (
          <ErrorState
            error={quotes.error}
            onRetry={() => void quotes.refetch()}
            retrying={quotes.isRefetching}
          />
        ) : quotes.data.rows.length === 0 ? (
          <EmptyState
            icon={<FileText aria-hidden="true" />}
            title={filtered ? 'No quotes match these filters' : 'No quotes yet'}
            description={
              filtered
                ? 'Try another status or search.'
                : 'Create a quote to send an estimate your customer can approve online.'
            }
            action={
              !filtered && canManage ? (
                <Link to="/app/quotes/new" className={buttonClasses({ variant: 'primary' })}>
                  New quote
                </Link>
              ) : undefined
            }
          />
        ) : (
          <>
            <Table
              caption="Quotes"
              columns={columns}
              rows={quotes.data.rows}
              getRowId={(q) => q.id}
              rowHref={(q) => `/app/quotes/${q.id}`}
            />
            <Pagination
              className="border-line border-t px-4 py-3"
              page={page}
              pageSize={QUOTE_PAGE_SIZE}
              total={quotes.data.total}
              onPageChange={(next) => update({ page: next })}
            />
          </>
        )}
      </Card>
    </>
  );
}
