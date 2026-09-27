import { Users } from 'lucide-react';
import { Badge, EmptyState, SectionCard, Table, type Column } from '@/components/ui';
import { bpsToPercentInput, formatBps, formatCents } from '@/lib/money';
import { ROLE_LABELS } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { useTeamReport } from '../api';
import { centsCell, toCsv } from '../csv';
import { formatCount, formatHours, teamHasPay, type TeamRow } from '../model';
import { rangeFileSuffix, type DateRange } from '../ranges';
import { CsvButton, ReportState } from './shared';

export function TeamReport({ range, ownOnly }: { range: DateRange; ownOnly: boolean }) {
  const query = useTeamReport(range);
  return (
    <ReportState query={query} title="Team">
      {() => <TeamBody rows={query.data ?? []} range={range} ownOnly={ownOnly} />}
    </ReportState>
  );
}

function TeamBody({
  rows,
  range,
  ownOnly,
}: {
  rows: TeamRow[];
  range: DateRange;
  ownOnly: boolean;
}) {
  const { currency } = useShop();
  const money = (cents: number | null) => formatCents(cents, { currency });
  const showPay = teamHasPay(rows);

  if (rows.length === 0)
    return (
      <SectionCard title={ownOnly ? 'My numbers' : 'Team'}>
        <EmptyState
          icon={<Users aria-hidden="true" />}
          title="No hours or completed jobs in this period"
        />
      </SectionCard>
    );

  const columns: Column<TeamRow>[] = [
    {
      key: 'member',
      header: 'Member',
      primary: true,
      cell: (r) => (
        <span className="flex flex-wrap items-center gap-1.5">
          <span className="font-medium">{r.display_name}</span>
          <span className="text-muted text-xs font-normal">{ROLE_LABELS[r.role]}</span>
          {!r.active && <Badge tone="neutral">Inactive</Badge>}
        </span>
      ),
    },
    { key: 'hours', header: 'Hours', align: 'right', cell: (r) => formatHours(r.hours) },
    {
      key: 'jobs',
      header: 'Jobs completed',
      align: 'right',
      cell: (r) => formatCount(r.jobs_completed),
    },
    { key: 'revenue', header: 'Revenue', align: 'right', cell: (r) => money(r.revenue_cents) },
    {
      key: 'pretax',
      header: 'Pre-tax revenue',
      align: 'right',
      hideOnMobile: !showPay,
      cell: (r) => money(r.pre_tax_revenue_cents),
    },
    ...(showPay
      ? ([
          {
            key: 'rate',
            header: 'Hourly rate',
            align: 'right',
            cell: (r) => money(r.hourly_rate_cents),
          },
          {
            key: 'commissionRate',
            header: 'Commission %',
            align: 'right',
            cell: (r) => formatBps(r.commission_bps),
          },
          {
            key: 'commission',
            header: 'Commission',
            align: 'right',
            cell: (r) => money(r.commission_cents),
          },
          {
            key: 'labor',
            header: 'Labor cost',
            align: 'right',
            cell: (r) => money(r.labor_cost_cents),
          },
        ] satisfies Column<TeamRow>[])
      : []),
  ];

  const header = [
    'Member',
    'Role',
    'Active',
    'Hours',
    'Jobs completed',
    'Revenue',
    'Pre-tax revenue',
  ];
  if (showPay) header.push('Hourly rate', 'Commission %', 'Commission', 'Labor cost');
  const csv = () =>
    toCsv(
      header,
      rows.map((r) => {
        const base = [
          r.display_name,
          ROLE_LABELS[r.role],
          r.active ? 'Yes' : 'No',
          r.hours,
          r.jobs_completed,
          centsCell(r.revenue_cents),
          centsCell(r.pre_tax_revenue_cents),
        ];
        return showPay
          ? [
              ...base,
              centsCell(r.hourly_rate_cents),
              bpsToPercentInput(r.commission_bps),
              centsCell(r.commission_cents),
              centsCell(r.labor_cost_cents),
            ]
          : base;
      }),
    );

  return (
    <SectionCard
      title={ownOnly ? 'My numbers' : 'Team'}
      description="Hours from the time clock; revenue from completed jobs, split evenly between assigned members."
      flush
      actions={<CsvButton filename={`team_${rangeFileSuffix(range)}.csv`} build={csv} />}
    >
      <Table
        caption="Team performance"
        columns={columns}
        rows={rows}
        getRowId={(r) => r.member_id}
      />
    </SectionCard>
  );
}
