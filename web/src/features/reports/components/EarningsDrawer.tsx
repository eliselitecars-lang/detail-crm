import { Receipt } from 'lucide-react';
import { Link } from 'react-router';
import { Drawer, EmptyState, Table, type Column } from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useMemberEarnings } from '../api';
import { centsCell, toCsv } from '../csv';
import { formatHours, sumEarnings, type MemberEarningsRow } from '../model';
import { rangeFileSuffix, type DateRange } from '../ranges';
import { CsvButton, ReportState, StatGrid, StatTile } from './shared';

/**
 * Per-job earnings of one member for the period (report_member_earnings,
 * 0065): revenue share, commission, service and sales commission, tips.
 * Owners and admins may open anyone's; everyone else only their own.
 */
export function EarningsDrawer({
  memberId,
  name,
  range,
  onClose,
}: {
  memberId: string;
  name: string;
  range: DateRange;
  onClose: () => void;
}) {
  const query = useMemberEarnings(memberId, range);
  return (
    <Drawer
      open
      onClose={onClose}
      title={`${name} · earnings by job`}
      description={`${range.from} to ${range.to}. Jobs completed in the period that ${name} worked on or sold.`}
      widthClassName="max-w-3xl"
    >
      <ReportState query={query} title="Earnings">
        {() => <EarningsBody rows={query.data ?? []} name={name} range={range} />}
      </ReportState>
    </Drawer>
  );
}

function EarningsBody({
  rows,
  name,
  range,
}: {
  rows: MemberEarningsRow[];
  name: string;
  range: DateRange;
}) {
  const { currency, timezone } = useShop();
  const canOpenJobs = useCan('jobs.viewAssigned');
  const money = (cents: number) => formatCents(cents, { currency });

  if (rows.length === 0)
    return (
      <EmptyState
        icon={<Receipt aria-hidden="true" />}
        title="No completed jobs in this period"
        description="Jobs count when they are completed, split between the members assigned to them."
      />
    );

  const t = sumEarnings(rows);
  const columns: Column<MemberEarningsRow>[] = [
    {
      key: 'job',
      header: 'Job',
      primary: true,
      cell: (r) =>
        canOpenJobs ? (
          <Link
            to={`/app/jobs/${r.job_id}`}
            className="text-primary-ink font-medium hover:underline"
          >
            #{r.job_number}
          </Link>
        ) : (
          `#${r.job_number}`
        ),
    },
    { key: 'done', header: 'Completed', cell: (r) => formatDate(r.completed_at, timezone) },
    {
      key: 'customer',
      header: 'Customer',
      hideOnMobile: true,
      cell: (r) => r.customer_label ?? '—',
    },
    { key: 'hours', header: 'Hours', align: 'right', cell: (r) => formatHours(r.hours) },
    {
      key: 'share',
      header: 'Revenue share',
      align: 'right',
      cell: (r) => money(r.revenue_share_cents),
    },
    {
      key: 'commission',
      header: 'Commission',
      align: 'right',
      cell: (r) => money(r.commission_cents),
    },
    {
      key: 'service',
      header: 'Service commission',
      align: 'right',
      cell: (r) => money(r.service_commission_cents),
    },
    {
      key: 'sales',
      header: 'Sales commission',
      align: 'right',
      cell: (r) => money(r.sales_commission_cents),
    },
    { key: 'tips', header: 'Tips', align: 'right', cell: (r) => money(r.tips_cents) },
  ];

  const csv = () =>
    toCsv(
      [
        'Job',
        'Completed',
        'Customer',
        'Hours',
        'Revenue share',
        'Commission',
        'Service commission',
        'Sales commission',
        'Tips',
      ],
      rows.map((r) => [
        r.job_number,
        formatDate(r.completed_at, timezone),
        r.customer_label,
        r.hours,
        centsCell(r.revenue_share_cents),
        centsCell(r.commission_cents),
        centsCell(r.service_commission_cents),
        centsCell(r.sales_commission_cents),
        centsCell(r.tips_cents),
      ]),
    );

  const slug =
    name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-|-$/g, '') || 'member';

  return (
    <div className="flex flex-col gap-4">
      <StatGrid label="Earnings totals">
        <StatTile
          label="Commission"
          value={money(t.commission)}
          hint={`${formatHours(t.hours)} on jobs`}
        />
        <StatTile label="Service commission" value={money(t.serviceCommission)} />
        <StatTile label="Sales commission" value={money(t.salesCommission)} />
        <StatTile label="Tips" value={money(t.tips)} hint="Never counted as revenue" />
      </StatGrid>
      <div className="flex justify-end">
        <CsvButton filename={`earnings_${slug}_${rangeFileSuffix(range)}.csv`} build={csv} />
      </div>
      <Table
        caption={`${name}: earnings by job`}
        columns={columns}
        rows={rows}
        getRowId={(r) => r.job_id}
      />
      <p className="text-muted text-xs">
        Hourly pay isn’t per job, so it appears only in the team total. Commissions are rounded on
        the period total and spread over the jobs, so the rows add up to the team report.
      </p>
    </div>
  );
}
