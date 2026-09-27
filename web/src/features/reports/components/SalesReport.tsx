import { Tags } from 'lucide-react';
import { Link } from 'react-router';
import { Badge, EmptyState, SectionCard, Table, type Column } from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useSalesReport } from '../api';
import { centsCell, toCsv } from '../csv';
import { formatCount, type SalesRow } from '../model';
import { rangeFileSuffix, type DateRange } from '../ranges';
import { CsvButton, ReportState } from './shared';

const KIND_LABELS = { service: 'Service', package: 'Package', addon: 'Add-on', product: 'Product' };

function rowId(r: SalesRow, index: number): string {
  return r.service_id ?? `custom-${index}-${r.service_name ?? ''}`;
}

export function SalesReport({ range }: { range: DateRange }) {
  const query = useSalesReport(range);
  return (
    <ReportState query={query} title="Sales by service">
      {() => <SalesBody rows={query.data ?? []} range={range} />}
    </ReportState>
  );
}

function SalesBody({ rows, range }: { rows: SalesRow[]; range: DateRange }) {
  const { currency } = useShop();
  const money = (cents: number) => formatCents(cents, { currency });
  const ids = new Map(rows.map((r, i) => [r, rowId(r, i)]));

  if (rows.length === 0)
    return (
      <SectionCard title="Sales by service">
        <EmptyState
          icon={<Tags aria-hidden="true" />}
          title="No completed jobs in this period"
          description="Sales are counted when a job is marked completed."
        />
      </SectionCard>
    );

  const columns: Column<SalesRow>[] = [
    {
      key: 'service',
      header: 'Service',
      primary: true,
      cell: (r) => (
        <span className="flex flex-col">
          {r.service_id ? (
            <Link
              to={`/app/catalog/services/${r.service_id}`}
              className="text-ink hover:text-primary-ink font-medium hover:underline"
            >
              {r.service_name ?? 'Service'}
            </Link>
          ) : (
            <span className="font-medium">
              {r.service_name ?? 'Custom item'}{' '}
              <Badge tone="neutral" className="ml-1">
                Custom
              </Badge>
            </span>
          )}
          <span className="text-muted text-xs font-normal">
            {[r.service_kind ? KIND_LABELS[r.service_kind] : null, r.category_name]
              .filter(Boolean)
              .join(' · ')}
          </span>
        </span>
      ),
    },
    { key: 'qty', header: 'Qty', align: 'right', cell: (r) => formatCount(r.quantity) },
    { key: 'jobs', header: 'Jobs', align: 'right', cell: (r) => formatCount(r.jobs_count) },
    { key: 'gross', header: 'Gross', align: 'right', cell: (r) => money(r.gross_cents) },
    { key: 'discount', header: 'Discounts', align: 'right', cell: (r) => money(r.discount_cents) },
    {
      key: 'net',
      header: 'Net sales',
      align: 'right',
      cell: (r) => <span className="font-medium">{money(r.net_cents)}</span>,
    },
  ];

  const csv = () =>
    toCsv(
      ['Service', 'Type', 'Category', 'Quantity', 'Jobs', 'Gross', 'Discounts', 'Net sales'],
      rows.map((r) => [
        r.service_name ?? 'Custom item',
        r.service_kind ? KIND_LABELS[r.service_kind] : 'Custom',
        r.category_name,
        r.quantity,
        r.jobs_count,
        centsCell(r.gross_cents),
        centsCell(r.discount_cents),
        centsCell(r.net_cents),
      ]),
    );

  return (
    <SectionCard
      title="Sales by service"
      description="Completed jobs in the period, before tax. Job discounts are spread across lines."
      flush
      actions={
        <CsvButton filename={`sales_by_service_${rangeFileSuffix(range)}.csv`} build={csv} />
      }
    >
      <Table
        caption="Sales by service"
        columns={columns}
        rows={rows}
        getRowId={(r) => ids.get(r) ?? ''}
      />
    </SectionCard>
  );
}
