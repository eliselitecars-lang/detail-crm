import { UserRound } from 'lucide-react';
import { EmptyState, SectionCard, Table, type Column } from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { TOP_CUSTOMERS_LIMIT, useCustomersReport } from '../api';
import { centsCell, toCsv } from '../csv';
import { countOf, formatCount, type CustomersReport as Report, type TopCustomer } from '../model';
import { rangeFileSuffix, type DateRange } from '../ranges';
import { CsvButton, ReportState, StatGrid, StatTile } from './shared';

export function CustomersReport({ range }: { range: DateRange }) {
  const query = useCustomersReport(range);
  return (
    <ReportState query={query} title="Customers">
      {() => (query.data ? <CustomersBody report={query.data} range={range} /> : null)}
    </ReportState>
  );
}

function percent(part: number, whole: number): string | undefined {
  if (whole <= 0) return undefined;
  return `${Math.round((part / whole) * 100)}% of customers served`;
}

function CustomersBody({ report, range }: { report: Report; range: DateRange }) {
  const { currency, timezone } = useShop();
  const money = (cents: number | null) => formatCents(cents, { currency });
  const top = report.top_customers;

  const columns: Column<TopCustomer>[] = [
    {
      key: 'name',
      header: 'Customer',
      primary: true,
      cell: (c) => c.name ?? 'Unnamed customer',
    },
    {
      key: 'lifetime',
      header: 'Lifetime paid',
      align: 'right',
      cell: (c) => <span className="font-medium">{money(c.lifetime_net_cents)}</span>,
    },
    {
      key: 'jobs',
      header: 'Completed jobs',
      align: 'right',
      cell: (c) => formatCount(c.completed_jobs),
    },
    {
      key: 'last',
      header: 'Last visit',
      align: 'right',
      cell: (c) => formatDate(c.last_completed_at, timezone),
    },
  ];

  const csv = () =>
    toCsv(
      ['Customer', 'Lifetime paid', 'Completed jobs', 'Last visit'],
      top.map((c) => [
        c.name ?? '',
        centsCell(c.lifetime_net_cents),
        c.completed_jobs,
        c.last_completed_at ? formatDate(c.last_completed_at, timezone) : '',
      ]),
    );

  return (
    <div className="flex flex-col gap-5">
      <StatGrid label="Customer totals">
        <StatTile
          label="Customers served"
          value={formatCount(report.customers_served)}
          hint={countOf(report.completed_jobs, 'completed job')}
        />
        <StatTile
          label="New"
          value={formatCount(report.new_customers)}
          hint={percent(report.new_customers, report.customers_served) ?? 'First completed job'}
        />
        <StatTile
          label="Returning"
          value={formatCount(report.returning_customers)}
          hint={percent(report.returning_customers, report.customers_served) ?? 'Came back again'}
        />
        <StatTile
          label="Average ticket"
          value={money(report.average_ticket_cents)}
          hint={`${countOf(report.customers_created, 'new customer record')} added`}
        />
      </StatGrid>
      <SectionCard
        title="Top customers"
        description={`Up to ${TOP_CUSTOMERS_LIMIT} customers by lifetime payments (excluding tips) through the end of the period.`}
        flush
        actions={
          top.length > 0 ? (
            <CsvButton filename={`top_customers_${rangeFileSuffix(range)}.csv`} build={csv} />
          ) : undefined
        }
      >
        {top.length === 0 ? (
          <EmptyState
            compact
            icon={<UserRound aria-hidden="true" />}
            title="No paying customers yet"
            description="Customers appear here once they’ve paid for work."
          />
        ) : (
          <Table
            caption="Top customers"
            columns={columns}
            rows={top}
            getRowId={(c) => c.customer_id}
            rowHref={(c) => `/app/customers/${c.customer_id}`}
          />
        )}
      </SectionCard>
    </div>
  );
}
