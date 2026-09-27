import { CircleCheck } from 'lucide-react';
import { Badge, EmptyState, SectionCard, Table, type Column } from '@/components/ui';
import { formatDate, formatDateTime } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useOutstandingReport } from '../api';
import { centsCell, toCsv } from '../csv';
import {
  AGING_LABELS,
  countOf,
  formatCount,
  type OutstandingInvoice,
  type OutstandingReport as Report,
} from '../model';
import { CsvButton, ReportState, StatGrid, StatTile } from './shared';

export function OutstandingReport() {
  const query = useOutstandingReport();
  return (
    <ReportState query={query} title="Outstanding balances">
      {() => (query.data ? <OutstandingBody report={query.data} /> : null)}
    </ReportState>
  );
}

function OutstandingBody({ report }: { report: Report }) {
  const { currency, timezone } = useShop();
  const money = (cents: number) => formatCents(cents, { currency });

  if (report.count === 0)
    return (
      <SectionCard title="Outstanding balances">
        <EmptyState
          icon={<CircleCheck aria-hidden="true" />}
          title="Nothing outstanding"
          description="Every issued invoice is paid in full."
        />
      </SectionCard>
    );

  const columns: Column<OutstandingInvoice>[] = [
    {
      key: 'invoice',
      header: 'Invoice',
      primary: true,
      cell: (i) => `#${i.number}`,
    },
    { key: 'customer', header: 'Customer', cell: (i) => i.customer_name ?? 'Unnamed customer' },
    { key: 'due', header: 'Due', cell: (i) => formatDate(i.due_at ?? i.issued_at, timezone) },
    {
      key: 'age',
      header: 'Past due',
      align: 'right',
      cell: (i) =>
        i.overdue ? (
          <Badge tone={i.days_past_due > 30 ? 'danger' : 'warning'}>
            {i.days_past_due === 1 ? '1 day' : `${formatCount(i.days_past_due)} days`}
          </Badge>
        ) : (
          <Badge tone="neutral">Not yet due</Badge>
        ),
    },
    {
      key: 'total',
      header: 'Total',
      align: 'right',
      hideOnMobile: true,
      cell: (i) => money(i.total_cents),
    },
    {
      key: 'paid',
      header: 'Paid',
      align: 'right',
      hideOnMobile: true,
      cell: (i) => money(i.amount_paid_cents),
    },
    {
      key: 'balance',
      header: 'Balance',
      align: 'right',
      cell: (i) => <span className="text-money-ink font-semibold">{money(i.balance_cents)}</span>,
    },
  ];

  const csv = () =>
    toCsv(
      [
        'Invoice',
        'Customer',
        'Status',
        'Issued',
        'Due',
        'Days past due',
        'Aging',
        'Total',
        'Paid',
        'Balance',
      ],
      report.invoices.map((i) => [
        i.number,
        i.customer_name ?? '',
        i.status,
        i.issued_at ? formatDate(i.issued_at, timezone) : '',
        i.due_at ? formatDate(i.due_at, timezone) : '',
        i.days_past_due,
        AGING_LABELS[i.bucket],
        centsCell(i.total_cents),
        centsCell(i.amount_paid_cents),
        centsCell(i.balance_cents),
      ]),
    );

  return (
    <div className="flex flex-col gap-5">
      <StatGrid label="Outstanding totals">
        <StatTile
          label="Outstanding"
          value={money(report.balance_cents)}
          hint={countOf(report.count, 'open invoice')}
        />
        <StatTile
          label="Overdue"
          value={money(report.overdue_balance_cents)}
          hint={countOf(report.overdue_count, 'invoice')}
        />
      </StatGrid>
      <SectionCard
        title="Aging"
        description={`As of ${formatDateTime(report.as_of, timezone)}. Days past the due date, in your shop’s time zone.`}
      >
        <ul className="grid grid-cols-2 gap-3 sm:grid-cols-4" aria-label="Aging buckets">
          {report.buckets.map((b) => (
            <li key={b.bucket} className="flex flex-col">
              <span className="text-muted text-xs">{AGING_LABELS[b.bucket]}</span>
              <span className="tabular text-ink font-semibold">{money(b.balance_cents)}</span>
              <span className="text-muted text-xs">{countOf(b.count, 'invoice')}</span>
            </li>
          ))}
        </ul>
      </SectionCard>
      <SectionCard
        title="Open invoices"
        description="Oldest due date first."
        flush
        actions={<CsvButton filename="outstanding_invoices.csv" build={csv} />}
      >
        <Table
          caption="Open invoices"
          columns={columns}
          rows={report.invoices}
          getRowId={(i) => i.invoice_id}
          rowHref={(i) => `/app/invoices/${i.invoice_id}`}
        />
      </SectionCard>
    </div>
  );
}
