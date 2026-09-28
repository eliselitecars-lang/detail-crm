import { Download, FileInput, Undo2, Wallet } from 'lucide-react';
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import {
  Badge,
  Button,
  Card,
  Checkbox,
  DateInput,
  EmptyState,
  ErrorState,
  FormField,
  LoadingState,
  PageHeader,
  Pagination,
  Select,
  Skeleton,
  StatusBadge,
  statusLabel,
  Table,
  useToast,
  type Column,
} from '@/components/ui';
import {
  addLocalDays,
  formatDateTime,
  formatLocalDate,
  isLocalDate,
  localDaysBetween,
  shopToday,
} from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useRealtime } from '@/lib/useRealtime';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { customerName } from '@/features/quotes/shared/format';
import { RefundDialog } from '@/features/invoices/components/RefundDialog';
import {
  fetchLedgerForExport,
  LEDGER_PAGE_SIZE,
  EXPORT_LIMIT,
  useLedger,
  usePaymentTotals,
  type LedgerFilters,
  type LedgerRow,
} from './api';
import { ApplyPaymentDialog } from './components/ApplyPaymentDialog';
import { downloadCsv, ledgerToCsv } from './csv';
import {
  canApplyToInvoice,
  isUnappliedPayment,
  KIND_LABELS,
  METHOD_LABELS,
  PAYMENT_KINDS,
  PAYMENT_METHODS,
  PAYMENT_STATUSES,
  paymentMethodLabel,
  refundableCents,
  type PaymentKind,
  type PaymentMethod,
  type PaymentStatus,
} from './paymentFormat';

function pick<T extends string>(value: string | null, allowed: readonly T[]): T | 'all' {
  return allowed.find((v) => v === value) ?? 'all';
}

export default function PaymentsPage() {
  const { shopId, timezone, currency } = useShop();
  const toast = useToast();
  const [params, setParams] = useSearchParams();
  const today = shopToday(timezone);
  const from = params.get('from') ?? addLocalDays(today, -29);
  const to = params.get('to') ?? today;
  const method = pick<PaymentMethod>(params.get('method'), PAYMENT_METHODS);
  const status = pick<PaymentStatus>(params.get('status'), PAYMENT_STATUSES);
  const kind = pick<PaymentKind>(params.get('kind'), PAYMENT_KINDS);
  const unapplied = params.get('unapplied') === '1';
  const page = Math.max(1, Number(params.get('page') ?? '1') || 1);
  const [exporting, setExporting] = useState(false);
  const canRefund = useCan('payments.refund');
  const canApply = useCan('invoices.manage');
  const [refunding, setRefunding] = useState<LedgerRow | null>(null);
  const [applying, setApplying] = useState<LedgerRow | null>(null);

  const rangeError =
    !isLocalDate(from) || !isLocalDate(to)
      ? 'Enter a valid date range.'
      : to < from
        ? 'The end date must be on or after the start date.'
        : localDaysBetween(from, to) > 3660
          ? 'Choose a range of 10 years or less.'
          : undefined;

  const filters: LedgerFilters = { from, to, method, status, kind, unapplied, page };
  const ledger = useLedger(filters, !rangeError);
  const { query: totalsQuery, totals } = usePaymentTotals(from, to, method, !rangeError);
  useRealtime({ table: 'payments', shopId });

  const setParam = (key: string, value: string | null) => {
    const next = new URLSearchParams(params);
    if (value === null || value === '' || value === 'all') next.delete(key);
    else next.set(key, value);
    next.delete('page');
    setParams(next, { replace: true });
  };

  const money = (cents: number) => formatCents(cents, { currency });

  const exportCsv = async () => {
    if (rangeError) return;
    setExporting(true);
    try {
      const { rows, truncated } = await fetchLedgerForExport(shopId, timezone, filters);
      downloadCsv(`payments-${from}-to-${to}.csv`, ledgerToCsv(rows, timezone));
      if (truncated) {
        toast.info(
          'Export limited',
          `Only the newest ${EXPORT_LIMIT.toLocaleString('en-US')} payments were exported. Narrow the dates.`,
        );
      } else {
        toast.success(`Exported ${rows.length} payment${rows.length === 1 ? '' : 's'}`);
      }
    } catch (error) {
      toast.error(error);
    } finally {
      setExporting(false);
    }
  };

  const columns: Column<LedgerRow>[] = [
    {
      key: 'date',
      header: 'Date',
      primary: true,
      cell: (p) => (
        <time dateTime={p.paid_at ?? p.created_at}>
          {formatDateTime(p.paid_at ?? p.created_at, timezone)}
        </time>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      cell: (p) => (
        <Link to={`/app/customers/${p.customer_id}`} className="text-primary-ink hover:underline">
          {customerName(p.customer)}
        </Link>
      ),
    },
    {
      key: 'ref',
      header: 'For',
      cell: (p) => (
        <span className="flex flex-col items-end gap-0.5 md:items-start">
          {p.invoice ? (
            <Link to={`/app/invoices/${p.invoice.id}`} className="text-primary-ink hover:underline">
              Invoice #{p.invoice.number}
            </Link>
          ) : p.job ? (
            <Link to={`/app/jobs/${p.job.id}`} className="text-primary-ink hover:underline">
              Job #{p.job.number}
            </Link>
          ) : p.membership_id ? (
            'Membership'
          ) : isUnappliedPayment(p) ? (
            <Badge tone="warning">Unapplied</Badge>
          ) : (
            '—'
          )}
          {p.note && (
            <span className="text-muted max-w-xs text-xs break-words whitespace-pre-line">
              {p.note}
            </span>
          )}
        </span>
      ),
    },
    {
      key: 'method',
      header: 'Method',
      cell: (p) => (
        <span className="inline-flex flex-wrap items-center justify-end gap-1.5 md:justify-start">
          {paymentMethodLabel(p)}
          {p.kind !== 'payment' && <Badge tone="neutral">{KIND_LABELS[p.kind]}</Badge>}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      cell: (p) => <StatusBadge kind="payment" status={p.status} />,
    },
    {
      key: 'amount',
      header: 'Amount',
      align: 'right',
      cell: (p) => (
        <span className="flex flex-col items-end tabular-nums">
          <span>{money(p.amount_cents)}</span>
          {p.tip_cents > 0 && (
            <span className="text-muted text-xs">+ {money(p.tip_cents)} tip</span>
          )}
          {p.refunded_cents > 0 && (
            <span className="text-danger-ink text-xs">−{money(p.refunded_cents)} refunded</span>
          )}
        </span>
      ),
    },
    {
      key: 'actions',
      header: <span className="sr-only">Actions</span>,
      align: 'right',
      cell: (p) => {
        const apply = canApply && canApplyToInvoice(p);
        const refund = canRefund && refundableCents(p) > 0;
        if (!apply && !refund) return null;
        return (
          <span className="inline-flex flex-wrap justify-end gap-1">
            {apply && (
              <Button
                size="sm"
                variant="secondary"
                leadingIcon={<FileInput className="size-4" aria-hidden="true" />}
                onClick={() => setApplying(p)}
                aria-label={`Apply ${money(p.amount_cents)} from ${customerName(p.customer)} to an invoice`}
              >
                Apply
              </Button>
            )}
            {refund && (
              <Button
                size="sm"
                variant="ghost"
                leadingIcon={<Undo2 className="size-4" aria-hidden="true" />}
                onClick={() => setRefunding(p)}
                aria-label={`Refund ${paymentMethodLabel(p)} payment of ${money(p.amount_cents)} from ${customerName(p.customer)}`}
              >
                Refund
              </Button>
            )}
          </span>
        );
      },
    },
  ];

  const selectOptions = <T extends string>(values: readonly T[], label: (v: T) => string) => [
    { value: 'all', label: 'All' },
    ...values.map((v) => ({ value: v, label: label(v) })),
  ];

  return (
    <>
      <PageHeader
        title="Payments"
        description="Card, cash and check payments, refunds and tips."
        actions={
          <Button
            variant="secondary"
            leadingIcon={<Download className="size-4" aria-hidden="true" />}
            onClick={() => void exportCsv()}
            loading={exporting}
            disabled={Boolean(rangeError)}
          >
            Export CSV
          </Button>
        }
      />

      <Card className="mb-4">
        <div className="grid grid-cols-1 gap-3 p-4 sm:grid-cols-2 lg:grid-cols-5">
          <FormField label="From" error={rangeError}>
            <DateInput value={from} max={to} onChange={(e) => setParam('from', e.target.value)} />
          </FormField>
          <FormField label="To">
            <DateInput value={to} min={from} onChange={(e) => setParam('to', e.target.value)} />
          </FormField>
          <FormField label="Method">
            <Select
              value={method}
              onChange={(e) => setParam('method', e.target.value)}
              options={selectOptions(PAYMENT_METHODS, (m) => METHOD_LABELS[m])}
            />
          </FormField>
          <FormField label="Status">
            <Select
              value={status}
              onChange={(e) => setParam('status', e.target.value)}
              options={selectOptions(PAYMENT_STATUSES, (s) => statusLabel('payment', s))}
            />
          </FormField>
          <FormField label="Kind">
            <Select
              value={kind}
              onChange={(e) => setParam('kind', e.target.value)}
              options={selectOptions(PAYMENT_KINDS, (k) => KIND_LABELS[k])}
            />
          </FormField>
        </div>
        <div className="border-line border-t px-4 py-3">
          <Checkbox
            checked={unapplied}
            onChange={(e) => setParam('unapplied', e.target.checked ? '1' : null)}
            label="Only unapplied money"
            description="Received money that pays no invoice, job or membership. Apply it to one of the customer’s invoices or refund it."
          />
        </div>
      </Card>

      <section aria-labelledby="payment-totals" className="mb-4">
        <h2 id="payment-totals" className="sr-only">
          Totals for these dates
        </h2>
        {totalsQuery.isError ? (
          <Card>
            <ErrorState
              compact
              title="Couldn’t load totals"
              error={totalsQuery.error}
              onRetry={() => void totalsQuery.refetch()}
            />
          </Card>
        ) : (
          <dl className="grid grid-cols-2 gap-3 lg:grid-cols-4">
            {[
              {
                key: 'collected',
                label: 'Collected (net, incl. tips)',
                value: totals?.collectedCents,
                money: true,
              },
              { key: 'gross', label: 'Gross payments', value: totals?.grossCents },
              { key: 'refunds', label: 'Refunds', value: totals?.refundsCents },
              { key: 'tips', label: 'Tips (net)', value: totals?.tipsCents },
            ].map((tile) => (
              <Card key={tile.key} padded>
                <dt className="text-muted text-xs font-medium">{tile.label}</dt>
                <dd
                  className={
                    tile.money
                      ? 'text-money-ink mt-1 text-lg font-semibold tabular-nums'
                      : 'text-ink mt-1 text-lg font-semibold tabular-nums'
                  }
                >
                  {rangeError ? (
                    // The totals query is off until the range is fixed: nothing is loading.
                    <>
                      <span aria-hidden="true">—</span>
                      <span className="sr-only">Not available</span>
                    </>
                  ) : tile.value === undefined ? (
                    <Skeleton className="h-6 w-24" />
                  ) : (
                    money(tile.value)
                  )}
                </dd>
              </Card>
            ))}
          </dl>
        )}
        <p className="text-muted mt-2 text-xs">
          {rangeError ? (
            'Fix the date range to see totals.'
          ) : (
            <>
              Totals cover money received from {formatLocalDate(from)} to {formatLocalDate(to)}
              {method !== 'all' ? ` by ${METHOD_LABELS[method].toLowerCase()}` : ''} (shop time);
              the status and kind filters apply to the list only.
              {totals ? ` ${totals.count} received payment${totals.count === 1 ? '' : 's'}.` : ''}
            </>
          )}
        </p>
      </section>

      <Card>
        {rangeError ? (
          <EmptyState compact title="Fix the date range to see payments" description={rangeError} />
        ) : ledger.isPending ? (
          <LoadingState variant="rows" rows={8} label="Loading payments…" />
        ) : ledger.isError ? (
          <ErrorState
            error={ledger.error}
            onRetry={() => void ledger.refetch()}
            retrying={ledger.isRefetching}
          />
        ) : ledger.data.rows.length === 0 ? (
          <EmptyState
            icon={<Wallet aria-hidden="true" />}
            title={unapplied ? 'No unapplied money in this period' : 'No payments in this period'}
            description="Try a wider date range or different filters."
          />
        ) : (
          <>
            <Table
              caption="Payments"
              columns={columns}
              rows={ledger.data.rows}
              getRowId={(p) => p.id}
            />
            <Pagination
              className="border-line border-t px-4 py-3"
              page={page}
              pageSize={LEDGER_PAGE_SIZE}
              total={ledger.data.total}
              onPageChange={(next) => {
                const merged = new URLSearchParams(params);
                if (next === 1) merged.delete('page');
                else merged.set('page', String(next));
                setParams(merged, { replace: true });
              }}
            />
          </>
        )}
      </Card>
      <RefundDialog payment={refunding} onClose={() => setRefunding(null)} currency={currency} />
      <ApplyPaymentDialog
        payment={applying}
        onClose={() => setApplying(null)}
        currency={currency}
      />
    </>
  );
}
