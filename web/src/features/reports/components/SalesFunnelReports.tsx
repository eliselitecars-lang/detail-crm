import { FileSearch, Magnet } from 'lucide-react';
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { EmptyState, SectionCard, Table, type Column } from '@/components/ui';
import { formatBps, formatCents } from '@/lib/money';
import { SOURCE_LABELS } from '@/features/customers/model';
import { useShop } from '@/features/shop/shopContext';
import { useLeadSourcesReport, useQuoteConversionReport } from '../api';
import { centsCell, toCsv } from '../csv';
import {
  countOf,
  formatCount,
  formatWaitHours,
  monthLabel,
  type LeadSourceRow,
  type QuoteConversion,
} from '../model';
import { rangeFileSuffix, type DateRange } from '../ranges';
import { CsvButton, ReportState, StatGrid, StatTile } from './shared';

const AXIS_TICK = { fill: 'var(--dc-muted)', fontSize: 11 };

// ---------------------------------------------------------------- lead sources

/** report_lead_sources (0078): new customers in the range by where they came from. */
export function LeadSourcesReport({ range }: { range: DateRange }) {
  const query = useLeadSourcesReport(range);
  return (
    <ReportState query={query} title="Lead sources">
      {() => <LeadSourcesBody rows={query.data ?? []} range={range} />}
    </ReportState>
  );
}

const LEAD_SERIES = [
  { key: 'converted_count', label: 'Became customers', color: 'var(--dc-primary)' },
  { key: 'leads_count', label: 'Still leads', color: 'var(--dc-line-strong)' },
] as const;

function LeadSourcesBody({ rows, range }: { rows: LeadSourceRow[]; range: DateRange }) {
  const { currency } = useShop();
  const money = (cents: number) => formatCents(cents, { currency });
  const used = rows.filter((r) => r.customers_count > 0);

  if (used.length === 0)
    return (
      <SectionCard title="Lead sources">
        <EmptyState
          icon={<Magnet aria-hidden="true" />}
          title="No new customers in this period"
          description="New customers and leads are grouped by the source set on their record."
        />
      </SectionCard>
    );

  const total = used.reduce((n, r) => n + r.customers_count, 0);
  const converted = used.reduce((n, r) => n + r.converted_count, 0);
  const revenue = used.reduce((n, r) => n + r.revenue_cents, 0);
  const chart = used.map((r) => ({ ...r, label: SOURCE_LABELS[r.source] }));

  const columns: Column<LeadSourceRow>[] = [
    {
      key: 'source',
      header: 'Source',
      primary: true,
      cell: (r) => SOURCE_LABELS[r.source],
    },
    { key: 'new', header: 'New', align: 'right', cell: (r) => formatCount(r.customers_count) },
    {
      key: 'converted',
      header: 'Became customers',
      align: 'right',
      cell: (r) => formatCount(r.converted_count),
    },
    {
      key: 'leads',
      header: 'Still leads',
      align: 'right',
      cell: (r) => formatCount(r.leads_count),
    },
    {
      key: 'rate',
      header: 'Conversion',
      align: 'right',
      cell: (r) =>
        r.customers_count > 0
          ? formatBps(Math.round((r.converted_count * 10000) / r.customers_count))
          : '—',
    },
    {
      key: 'first',
      header: 'First-job revenue',
      align: 'right',
      hideOnMobile: true,
      cell: (r) => money(r.first_job_revenue_cents),
    },
    { key: 'revenue', header: 'Received', align: 'right', cell: (r) => money(r.revenue_cents) },
  ];

  const csv = () =>
    toCsv(
      ['Source', 'New', 'Became customers', 'Still leads', 'First-job revenue', 'Received'],
      used.map((r) => [
        SOURCE_LABELS[r.source],
        r.customers_count,
        r.converted_count,
        r.leads_count,
        centsCell(r.first_job_revenue_cents),
        centsCell(r.revenue_cents),
      ]),
    );

  return (
    <div className="flex flex-col gap-5">
      <StatGrid label="Lead source totals">
        <StatTile label="New customers & leads" value={formatCount(total)} />
        <StatTile
          label="Became customers"
          value={formatCount(converted)}
          hint={
            total > 0 ? `${formatBps(Math.round((converted * 10000) / total))} of new` : undefined
          }
        />
        <StatTile label="Still leads" value={formatCount(total - converted)} />
        <StatTile
          label="Received from them"
          value={money(revenue)}
          hint="Through the end of the period"
        />
      </StatGrid>
      <SectionCard
        title="By source"
        description="Customers created in the period, by their source."
      >
        <div
          className="h-64 w-full sm:h-72"
          role="img"
          aria-label={`Lead sources chart: ${used
            .map((r) => `${SOURCE_LABELS[r.source]} ${r.customers_count}`)
            .join(', ')}. The table below has every number.`}
        >
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={chart} margin={{ top: 4, right: 4, bottom: 0, left: 0 }}>
              <CartesianGrid vertical={false} stroke="var(--dc-line)" />
              <XAxis
                dataKey="label"
                tick={AXIS_TICK}
                axisLine={{ stroke: 'var(--dc-line-strong)' }}
                tickLine={false}
                interval={0}
                minTickGap={4}
              />
              <YAxis
                allowDecimals={false}
                tick={AXIS_TICK}
                axisLine={false}
                tickLine={false}
                width={36}
              />
              <Tooltip
                cursor={{ fill: 'var(--dc-surface-2)' }}
                contentStyle={{
                  background: 'var(--dc-surface)',
                  border: '1px solid var(--dc-line)',
                  borderRadius: 8,
                  fontSize: 12,
                }}
              />
              <Legend wrapperStyle={{ fontSize: 12 }} />
              {LEAD_SERIES.map((s) => (
                <Bar
                  key={s.key}
                  dataKey={s.key}
                  name={s.label}
                  stackId="leads"
                  fill={s.color}
                  maxBarSize={40}
                  isAnimationActive={false}
                />
              ))}
            </BarChart>
          </ResponsiveContainer>
        </div>
      </SectionCard>
      <SectionCard
        title="Sources"
        description="First-job revenue is before tax; received is money paid by these customers through the end of the period (tips and refunds excluded)."
        flush
        actions={<CsvButton filename={`lead_sources_${rangeFileSuffix(range)}.csv`} build={csv} />}
      >
        <Table caption="Lead sources" columns={columns} rows={used} getRowId={(r) => r.source} />
      </SectionCard>
    </div>
  );
}

// ------------------------------------------------------------ quote conversion

/** report_quote_conversion (0078): quotes sent in the range and what became of them. */
export function QuoteConversionReport({ range }: { range: DateRange }) {
  const query = useQuoteConversionReport(range);
  return (
    <ReportState query={query} title="Quote conversion">
      {() => (query.data ? <QuoteConversionBody data={query.data} range={range} /> : null)}
    </ReportState>
  );
}

function QuoteConversionBody({ data, range }: { data: QuoteConversion; range: DateRange }) {
  const { currency } = useShop();
  const money = (cents: number | null) => formatCents(cents, { currency });

  if (data.sent === 0)
    return (
      <SectionCard title="Quote conversion">
        <EmptyState
          icon={<FileSearch aria-hidden="true" />}
          title="No quotes sent in this period"
          description="Quotes count from the day they were sent."
        />
      </SectionCard>
    );

  const funnel = [
    { label: 'Sent', value: data.sent },
    { label: 'Viewed', value: data.viewed },
    { label: 'Approved', value: data.approved },
    { label: 'Turned into jobs', value: data.converted },
  ];
  const months = data.by_month.map((m) => ({ ...m, label: monthLabel(m.month, true) }));

  const csv = () =>
    toCsv(
      ['Month', 'Sent', 'Approved', 'Approved value'],
      data.by_month.map((m) => [m.month, m.sent, m.approved, centsCell(m.approved_cents)]),
    );

  return (
    <div className="flex flex-col gap-5">
      <StatGrid label="Quote conversion totals">
        <StatTile
          label="Approval rate"
          value={formatBps(data.conversion_rate_bps)}
          hint={`${countOf(data.approved, 'approved quote')} of ${formatCount(data.sent)} sent`}
        />
        <StatTile label="Average quote" value={money(data.average_quote_cents)} />
        <StatTile label="Average approved" value={money(data.average_approved_cents)} />
        <StatTile
          label="Typical time to approve"
          value={formatWaitHours(data.median_hours_to_approve)}
          hint="Median, from sending"
        />
      </StatGrid>

      <SectionCard title="Funnel" description="Approved includes quotes already turned into jobs.">
        <ol className="flex flex-col gap-2" aria-label="Quote funnel">
          {funnel.map((step) => {
            const pct = data.sent > 0 ? Math.round((step.value / data.sent) * 100) : 0;
            return (
              <li key={step.label} className="grid grid-cols-[8.5rem_1fr_auto] items-center gap-3">
                <span className="text-ink text-sm">{step.label}</span>
                <span className="bg-surface-2 h-3 overflow-hidden rounded-full" aria-hidden="true">
                  <span
                    className="bg-primary block h-full rounded-full"
                    style={{ width: `${pct}%` }}
                  />
                </span>
                <span className="text-ink tabular text-right text-sm">
                  {formatCount(step.value)}
                  <span className="text-muted text-xs"> ({pct}%)</span>
                </span>
              </li>
            );
          })}
        </ol>
        <p className="text-muted mt-3 text-sm">
          Declined {formatCount(data.declined)} · Expired {formatCount(data.expired)}
        </p>
      </SectionCard>

      <SectionCard
        title="By month"
        description="Quotes sent each month and how many of them were approved."
        actions={
          <CsvButton filename={`quote_conversion_${rangeFileSuffix(range)}.csv`} build={csv} />
        }
      >
        <div className="flex flex-col gap-4">
          <div
            className="h-64 w-full"
            role="img"
            aria-label={`Quotes by month: ${data.by_month
              .map((m) => `${monthLabel(m.month)} ${m.sent} sent, ${m.approved} approved`)
              .join('; ')}.`}
          >
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={months} margin={{ top: 4, right: 4, bottom: 0, left: 0 }} barGap={2}>
                <CartesianGrid vertical={false} stroke="var(--dc-line)" />
                <XAxis
                  dataKey="label"
                  tick={AXIS_TICK}
                  axisLine={{ stroke: 'var(--dc-line-strong)' }}
                  tickLine={false}
                  minTickGap={8}
                />
                <YAxis
                  allowDecimals={false}
                  tick={AXIS_TICK}
                  axisLine={false}
                  tickLine={false}
                  width={36}
                />
                <Tooltip
                  cursor={{ fill: 'var(--dc-surface-2)' }}
                  contentStyle={{
                    background: 'var(--dc-surface)',
                    border: '1px solid var(--dc-line)',
                    borderRadius: 8,
                    fontSize: 12,
                  }}
                />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <Bar
                  dataKey="sent"
                  name="Sent"
                  fill="var(--dc-line-strong)"
                  maxBarSize={28}
                  isAnimationActive={false}
                />
                <Bar
                  dataKey="approved"
                  name="Approved"
                  fill="var(--dc-primary)"
                  maxBarSize={28}
                  isAnimationActive={false}
                />
              </BarChart>
            </ResponsiveContainer>
          </div>
          <Table
            caption="Quotes by month"
            columns={[
              { key: 'month', header: 'Month', primary: true, cell: (m) => monthLabel(m.month) },
              { key: 'sent', header: 'Sent', align: 'right', cell: (m) => formatCount(m.sent) },
              {
                key: 'approved',
                header: 'Approved',
                align: 'right',
                cell: (m) => formatCount(m.approved),
              },
              {
                key: 'value',
                header: 'Approved value',
                align: 'right',
                cell: (m) => money(m.approved_cents),
              },
            ]}
            rows={data.by_month}
            getRowId={(m) => m.month}
          />
        </div>
      </SectionCard>
    </div>
  );
}
