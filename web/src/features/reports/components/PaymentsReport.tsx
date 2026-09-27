import { CreditCard } from 'lucide-react';
import { EmptyState, SectionCard, Table, type Column } from '@/components/ui';
import { formatCents, sumCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { usePaymentsReport } from '../api';
import { centsCell, toCsv } from '../csv';
import { formatCount, METHOD_LABELS, type PaymentsRow } from '../model';
import { rangeFileSuffix, type DateRange } from '../ranges';
import { CsvButton, ReportState, StatGrid, StatTile } from './shared';

export function PaymentsReport({ range }: { range: DateRange }) {
  const query = usePaymentsReport(range);
  return (
    <ReportState query={query} title="Payments">
      {() => <PaymentsBody rows={query.data ?? []} range={range} />}
    </ReportState>
  );
}

function PaymentsBody({ rows: all, range }: { rows: PaymentsRow[]; range: DateRange }) {
  const { currency } = useShop();
  const money = (cents: number) => formatCents(cents, { currency });
  // The server returns every method (zeros included); show the ones used.
  const rows = all.filter((r) => r.payments_count > 0);
  const disputesLost = sumCents(rows.map((r) => r.disputes_lost_cents));

  if (rows.length === 0)
    return (
      <SectionCard title="Payments by method">
        <EmptyState
          icon={<CreditCard aria-hidden="true" />}
          title="No payments in this period"
          description="Card, cash, check and other payments received show up here."
        />
      </SectionCard>
    );

  const columns: Column<PaymentsRow>[] = [
    { key: 'method', header: 'Method', primary: true, cell: (r) => METHOD_LABELS[r.method] },
    {
      key: 'count',
      header: 'Payments',
      align: 'right',
      cell: (r) => formatCount(r.payments_count),
    },
    { key: 'gross', header: 'Gross', align: 'right', cell: (r) => money(r.gross_cents) },
    { key: 'refunds', header: 'Refunds', align: 'right', cell: (r) => money(r.refunds_cents) },
    { key: 'net', header: 'Net', align: 'right', cell: (r) => money(r.net_cents) },
    { key: 'tips', header: 'Tips', align: 'right', cell: (r) => money(r.tips_cents) },
    {
      key: 'collected',
      header: 'Collected',
      align: 'right',
      cell: (r) => <span className="font-medium">{money(r.collected_cents)}</span>,
    },
    {
      key: 'deposits',
      header: 'Deposits',
      align: 'right',
      hideOnMobile: true,
      cell: (r) => money(r.deposits_cents),
    },
    {
      key: 'memberships',
      header: 'Memberships',
      align: 'right',
      hideOnMobile: true,
      cell: (r) => money(r.memberships_cents),
    },
  ];

  const csv = () =>
    toCsv(
      [
        'Method',
        'Payments',
        'Gross',
        'Refunds',
        'Net',
        'Tips',
        'Tip refunds',
        'Collected',
        'Deposits',
        'Memberships',
        'Lost disputes',
      ],
      rows.map((r) => [
        METHOD_LABELS[r.method],
        r.payments_count,
        centsCell(r.gross_cents),
        centsCell(r.refunds_cents),
        centsCell(r.net_cents),
        centsCell(r.tips_cents),
        centsCell(r.tip_refunds_cents),
        centsCell(r.collected_cents),
        centsCell(r.deposits_cents),
        centsCell(r.memberships_cents),
        centsCell(r.disputes_lost_cents),
      ]),
    );

  return (
    <div className="flex flex-col gap-5">
      <StatGrid label="Payment totals">
        <StatTile
          label="Collected"
          value={money(sumCents(rows.map((r) => r.collected_cents)))}
          hint="Net payments plus tips"
        />
        <StatTile label="Net" value={money(sumCents(rows.map((r) => r.net_cents)))} />
        <StatTile label="Refunds" value={money(sumCents(rows.map((r) => r.refunds_cents)))} />
        <StatTile label="Tips" value={money(sumCents(rows.map((r) => r.tips_cents)))} />
        {disputesLost > 0 && (
          <StatTile
            label="Lost disputes"
            value={money(disputesLost)}
            hint="Card payments the bank took back in a chargeback; balances are unchanged"
          />
        )}
      </StatGrid>
      <SectionCard
        title="Payments by method"
        description="Processor fees aren’t tracked, so they aren’t deducted here."
        flush
        actions={<CsvButton filename={`payments_${rangeFileSuffix(range)}.csv`} build={csv} />}
      >
        <Table
          caption="Payments by method"
          columns={columns}
          rows={rows}
          getRowId={(r) => r.method}
        />
      </SectionCard>
    </div>
  );
}
