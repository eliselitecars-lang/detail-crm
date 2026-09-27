import { BarChart3 } from 'lucide-react';
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import {
  EmptyState,
  ErrorState,
  LoadingState,
  SectionCard,
  Table,
  type Column,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useRevenueReport, useRevenueTotals } from '../api';
import { centsCell, toCsv } from '../csv';
import { countOf, formatCount, type RevenueRow } from '../model';
import { bucketLabel, rangeFileSuffix, type Bucket, type DateRange } from '../ranges';
import { CsvButton, ReportState, StatGrid, StatTile } from './shared';

/** Series → design tokens (validated palette: primary / danger / money). */
const SERIES = [
  { key: 'net_cents', label: 'Net revenue', color: 'var(--dc-primary)', stack: 'cash' },
  { key: 'refunds_cents', label: 'Refunds', color: 'var(--dc-danger)', stack: 'cash' },
  { key: 'tips_cents', label: 'Tips', color: 'var(--dc-money)', stack: undefined },
] as const;

type TotalsQuery = ReturnType<typeof useRevenueTotals>;

export function RevenueReport({ range, bucket }: { range: DateRange; bucket: Bucket }) {
  const query = useRevenueReport(range, bucket);
  // The summary cards come from their own RPC (report_revenue_totals), so a
  // failure there shows an error on the cards without hiding the chart.
  const totals = useRevenueTotals(range);
  return (
    <ReportState query={query} title="Revenue">
      {() => <RevenueBody rows={query.data ?? []} totals={totals} range={range} bucket={bucket} />}
    </ReportState>
  );
}

function TotalTiles({ totals }: { totals: TotalsQuery }) {
  const { currency } = useShop();
  const money = (cents: number) => formatCents(cents, { currency });
  if (totals.isPending) return <LoadingState label="Loading revenue totals…" />;
  if (totals.isError) {
    return (
      <ErrorState
        compact
        error={totals.error}
        title="Couldn’t load the revenue totals"
        onRetry={() => void totals.refetch()}
        retrying={totals.isRefetching}
      />
    );
  }
  const t = totals.data;
  return (
    <StatGrid label="Revenue totals">
      <StatTile
        label="Net revenue"
        value={money(t.net_cents)}
        hint="Gross minus refunds, excluding tips"
      />
      <StatTile
        label="Gross"
        value={money(t.gross_cents)}
        hint={countOf(t.payments_count, 'payment')}
      />
      <StatTile label="Refunds" value={money(t.refunds_cents)} />
      <StatTile label="Tips" value={money(t.tips_cents)} hint="Never counted as revenue" />
    </StatGrid>
  );
}

function RevenueBody({
  rows,
  totals,
  range,
  bucket,
}: {
  rows: RevenueRow[];
  totals: TotalsQuery;
  range: DateRange;
  bucket: Bucket;
}) {
  const { currency } = useShop();
  const money = (cents: number) => formatCents(cents, { currency });
  // Any payment at all? The totals say so; until they load, the periods do.
  const paymentsCount = totals.data
    ? totals.data.payments_count
    : rows.reduce((n, r) => n + r.payments_count, 0);

  if (paymentsCount === 0)
    return (
      <SectionCard title="Revenue">
        <EmptyState
          icon={<BarChart3 aria-hidden="true" />}
          title="No payments in this period"
          description="Received payments show up here by the day they were paid."
        />
      </SectionCard>
    );

  const byBucket = new Map(rows.map((r) => [r.bucket_start, r]));
  const columns: Column<RevenueRow>[] = [
    {
      key: 'bucket',
      header: bucket === 'day' ? 'Day' : bucket === 'week' ? 'Week' : 'Month',
      primary: true,
      cell: (r) => bucketLabel(r.bucket_start, bucket),
    },
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
  ];

  const csv = () =>
    toCsv(
      ['Period start', 'Payments', 'Gross', 'Refunds', 'Net', 'Tips'],
      rows.map((r) => [
        r.bucket_start,
        r.payments_count,
        centsCell(r.gross_cents),
        centsCell(r.refunds_cents),
        centsCell(r.net_cents),
        centsCell(r.tips_cents),
      ]),
    );

  return (
    <div className="flex flex-col gap-5">
      <TotalTiles totals={totals} />

      <SectionCard
        title="Revenue over time"
        description="Bar height is gross; tips are shown separately."
      >
        <div className="flex flex-col gap-3">
          <ul className="flex flex-wrap gap-x-4 gap-y-1 text-xs" aria-label="Legend">
            {SERIES.map((s) => (
              <li key={s.key} className="text-muted flex items-center gap-1.5">
                <span
                  aria-hidden="true"
                  className="size-2.5 rounded-sm"
                  style={{ background: s.color }}
                />
                {s.label}
              </li>
            ))}
          </ul>
          <div
            className="h-64 w-full sm:h-72"
            role="img"
            aria-label={
              totals.data
                ? `Revenue chart: net ${money(totals.data.net_cents)}, refunds ${money(totals.data.refunds_cents)}, tips ${money(totals.data.tips_cents)}. The table below lists every period.`
                : 'Revenue chart. The table below lists every period.'
            }
          >
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={rows} margin={{ top: 4, right: 4, bottom: 0, left: 0 }} barGap={2}>
                <CartesianGrid vertical={false} stroke="var(--dc-line)" />
                <XAxis
                  dataKey="bucket_start"
                  tickFormatter={(v: string) => bucketLabel(v, bucket, true)}
                  tick={{ fill: 'var(--dc-muted)', fontSize: 11 }}
                  axisLine={{ stroke: 'var(--dc-line-strong)' }}
                  tickLine={false}
                  minTickGap={12}
                />
                <YAxis
                  tickFormatter={(v: number) => formatCents(v, { currency, compactWhole: true })}
                  tick={{ fill: 'var(--dc-muted)', fontSize: 11 }}
                  axisLine={false}
                  tickLine={false}
                  width={72}
                />
                <Tooltip
                  cursor={{ fill: 'var(--dc-surface-2)' }}
                  content={({ active, label }) => {
                    const row =
                      active && typeof label === 'string' ? byBucket.get(label) : undefined;
                    if (!row) return null;
                    return (
                      <div className="rounded-control border-line bg-surface shadow-pop border px-3 py-2 text-xs">
                        <p className="text-ink mb-1 font-semibold">
                          {bucketLabel(row.bucket_start, bucket)}
                        </p>
                        <dl className="grid grid-cols-[auto_auto] gap-x-3 gap-y-0.5">
                          <dt className="text-muted">Gross</dt>
                          <dd className="tabular text-ink text-right">{money(row.gross_cents)}</dd>
                          {SERIES.map((s) => (
                            <div key={s.key} className="contents">
                              <dt className="text-muted flex items-center gap-1.5">
                                <span
                                  aria-hidden="true"
                                  className="size-2 rounded-sm"
                                  style={{ background: s.color }}
                                />
                                {s.label}
                              </dt>
                              <dd className="tabular text-ink text-right">{money(row[s.key])}</dd>
                            </div>
                          ))}
                          <dt className="text-muted">Payments</dt>
                          <dd className="tabular text-ink text-right">
                            {formatCount(row.payments_count)}
                          </dd>
                        </dl>
                      </div>
                    );
                  }}
                />
                {SERIES.map((s, i) => (
                  <Bar
                    key={s.key}
                    dataKey={s.key}
                    name={s.label}
                    fill={s.color}
                    stackId={s.stack}
                    maxBarSize={36}
                    radius={s.key === 'net_cents' ? 0 : [4, 4, 0, 0]}
                    stroke="var(--dc-surface)"
                    strokeWidth={i < 2 ? 1 : 0}
                    isAnimationActive={false}
                  />
                ))}
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>
      </SectionCard>

      <SectionCard
        title="By period"
        flush
        actions={<CsvButton filename={`revenue_${rangeFileSuffix(range)}.csv`} build={csv} />}
      >
        <Table
          caption="Revenue by period"
          columns={columns}
          rows={rows}
          getRowId={(r) => r.bucket_start}
        />
      </SectionCard>
    </div>
  );
}
