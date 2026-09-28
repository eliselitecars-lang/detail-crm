import { PiggyBank } from 'lucide-react';
import { Link } from 'react-router';
import { EmptyState, SectionCard, Table, type Column } from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatBps, formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useJobProfitReport, useServiceProfitReport } from '../api';
import { centsCell, toCsv } from '../csv';
import { countOf, formatCount, type JobProfitRow, type ServiceProfitRow } from '../model';
import { rangeFileSuffix, type DateRange } from '../ranges';
import { CsvButton, ReportState, StatGrid, StatTile } from './shared';

const NOTE =
  'Materials are the stock used by completed jobs (at the product cost when it was used). Enter product costs in Inventory.';

/** report_job_profit (0078): revenue − materials − labor per completed job. */
export function JobProfitReport({ range }: { range: DateRange }) {
  const query = useJobProfitReport(range);
  return (
    <ReportState query={query} title="Job profit">
      {() => <JobProfitBody rows={query.data ?? []} range={range} />}
    </ReportState>
  );
}

function JobProfitBody({ rows, range }: { rows: JobProfitRow[]; range: DateRange }) {
  const { currency, timezone } = useShop();
  const money = (cents: number | null) => formatCents(cents, { currency });
  // Labor (pay) is owners / admins only: the server sends null to managers.
  const showLabor = rows.some((r) => r.labor_cents !== null);

  if (rows.length === 0)
    return (
      <SectionCard title="Job profit">
        <EmptyState
          icon={<PiggyBank aria-hidden="true" />}
          title="No completed jobs in this period"
          description="Each completed job shows its revenue, materials used and labor."
        />
      </SectionCard>
    );

  const revenue = rows.reduce((n, r) => n + r.revenue_cents, 0);
  const materials = rows.reduce((n, r) => n + r.materials_cents, 0);
  const labor = rows.reduce((n, r) => n + (r.labor_cents ?? 0), 0);

  const columns: Column<JobProfitRow>[] = [
    {
      key: 'job',
      header: 'Job',
      primary: true,
      cell: (r) => (
        <Link to={`/app/jobs/${r.job_id}`} className="text-primary-ink font-medium hover:underline">
          #{r.job_number}
        </Link>
      ),
    },
    { key: 'done', header: 'Completed', cell: (r) => formatDate(r.completed_at, timezone) },
    {
      key: 'customer',
      header: 'Customer',
      hideOnMobile: true,
      cell: (r) => r.customer_label ?? '—',
    },
    { key: 'revenue', header: 'Revenue', align: 'right', cell: (r) => money(r.revenue_cents) },
    {
      key: 'materials',
      header: 'Materials',
      align: 'right',
      cell: (r) => money(r.materials_cents),
    },
    ...(showLabor
      ? ([
          { key: 'labor', header: 'Labor', align: 'right', cell: (r) => money(r.labor_cents) },
          {
            key: 'profit',
            header: 'Profit',
            align: 'right',
            cell: (r) => <span className="font-medium">{money(r.profit_cents)}</span>,
          },
          { key: 'margin', header: 'Margin', align: 'right', cell: (r) => formatBps(r.margin_bps) },
        ] satisfies Column<JobProfitRow>[])
      : []),
  ];

  const header = ['Job', 'Completed', 'Customer', 'Revenue', 'Materials'];
  if (showLabor) header.push('Labor', 'Profit', 'Margin %');
  const csv = () =>
    toCsv(
      header,
      rows.map((r) => [
        r.job_number,
        formatDate(r.completed_at, timezone),
        r.customer_label,
        centsCell(r.revenue_cents),
        centsCell(r.materials_cents),
        ...(showLabor
          ? [
              centsCell(r.labor_cents),
              centsCell(r.profit_cents),
              r.margin_bps === null ? '' : (r.margin_bps / 100).toFixed(2),
            ]
          : []),
      ]),
    );

  return (
    <div className="flex flex-col gap-5">
      <StatGrid label="Job profit totals">
        <StatTile label="Revenue" value={money(revenue)} hint={countOf(rows.length, 'job')} />
        <StatTile label="Materials" value={money(materials)} />
        {showLabor ? (
          <>
            <StatTile label="Labor" value={money(labor)} hint="Hours on each job × pay rate" />
            <StatTile label="Profit" value={money(revenue - materials - labor)} />
          </>
        ) : (
          <StatTile label="After materials" value={money(revenue - materials)} />
        )}
      </StatGrid>
      <SectionCard
        title="By job"
        description={`Revenue before tax, after discounts. ${NOTE}${showLabor ? '' : ' Labor and profit are visible to owners and admins.'}`}
        flush
        actions={<CsvButton filename={`job_profit_${rangeFileSuffix(range)}.csv`} build={csv} />}
      >
        <Table caption="Job profit" columns={columns} rows={rows} getRowId={(r) => r.job_id} />
      </SectionCard>
    </div>
  );
}

/** report_service_profit (0078): revenue − materials per catalog service. */
export function ServiceProfitReport({ range }: { range: DateRange }) {
  const query = useServiceProfitReport(range);
  return (
    <ReportState query={query} title="Service profit">
      {() => <ServiceProfitBody rows={query.data ?? []} range={range} />}
    </ReportState>
  );
}

function ServiceProfitBody({ rows, range }: { rows: ServiceProfitRow[]; range: DateRange }) {
  const { currency } = useShop();
  const money = (cents: number) => formatCents(cents, { currency });

  if (rows.length === 0)
    return (
      <SectionCard title="Service profit">
        <EmptyState
          icon={<PiggyBank aria-hidden="true" />}
          title="No services sold in this period"
          description="Catalog services on completed jobs show their revenue and materials here."
        />
      </SectionCard>
    );

  const columns: Column<ServiceProfitRow>[] = [
    {
      key: 'service',
      header: 'Service',
      primary: true,
      cell: (r) => r.service_name ?? 'Deleted service',
    },
    { key: 'jobs', header: 'Jobs', align: 'right', cell: (r) => formatCount(r.jobs_count) },
    { key: 'revenue', header: 'Revenue', align: 'right', cell: (r) => money(r.revenue_cents) },
    {
      key: 'materials',
      header: 'Materials',
      align: 'right',
      cell: (r) => money(r.materials_cents),
    },
    {
      key: 'profit',
      header: 'Gross profit',
      align: 'right',
      cell: (r) => <span className="font-medium">{money(r.gross_profit_cents)}</span>,
    },
    { key: 'margin', header: 'Margin', align: 'right', cell: (r) => formatBps(r.margin_bps) },
  ];

  const csv = () =>
    toCsv(
      ['Service', 'Jobs', 'Revenue', 'Materials', 'Gross profit', 'Margin %'],
      rows.map((r) => [
        r.service_name,
        r.jobs_count,
        centsCell(r.revenue_cents),
        centsCell(r.materials_cents),
        centsCell(r.gross_profit_cents),
        r.margin_bps === null ? '' : (r.margin_bps / 100).toFixed(2),
      ]),
    );

  return (
    <SectionCard
      title="Service profit"
      description={`Revenue of each catalog service on completed jobs (before tax, with the job discount spread over its lines) minus the materials it used. Custom lines are left out. ${NOTE}`}
      flush
      actions={<CsvButton filename={`service_profit_${rangeFileSuffix(range)}.csv`} build={csv} />}
    >
      <Table
        caption="Service profit"
        columns={columns}
        rows={rows}
        getRowId={(r) => r.service_id}
      />
    </SectionCard>
  );
}
