import { CalendarRange } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import { useSearchParams } from 'react-router';
import { Card, EmptyState, PageHeader, Tabs, type TabItem } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { CustomersReport } from './components/CustomersReport';
import { OutstandingReport } from './components/OutstandingReport';
import { PaymentsReport } from './components/PaymentsReport';
import { RangePicker } from './components/RangePicker';
import { RevenueReport } from './components/RevenueReport';
import { SalesReport } from './components/SalesReport';
import { TeamReport } from './components/TeamReport';
import { readParams, type Bucket, type DateRange, type Preset } from './ranges';

const ALL_TABS = ['revenue', 'payments', 'sales', 'team', 'customers', 'outstanding'] as const;
type ReportTab = (typeof ALL_TABS)[number];

const TAB_LABELS: Record<ReportTab, string> = {
  revenue: 'Revenue',
  payments: 'Payments',
  sales: 'Sales by service',
  team: 'Team',
  customers: 'Customers',
  outstanding: 'Outstanding',
};

export default function ReportsPage() {
  const { timezone } = useShop();
  // Technicians only get their own team row (report_team); the other
  // reports are manager+ on the server too.
  const canViewAll = useCan('reports.view');
  const [params, setParams] = useSearchParams();
  const [now] = useState(() => new Date());
  const { preset, range, bucket, valid, error } = readParams(params, timezone, now);

  const tabs: readonly ReportTab[] = canViewAll ? ALL_TABS : ['team'];
  const rawTab = params.get('tab');
  const tab: ReportTab = tabs.find((t) => t === rawTab) ?? tabs[0] ?? 'team';

  const update = (patch: Record<string, string | null>) => {
    const next = new URLSearchParams(params);
    for (const [key, value] of Object.entries(patch)) {
      if (value === null) next.delete(key);
      else next.set(key, value);
    }
    setParams(next, { replace: true });
  };

  const onPresetChange = (nextPreset: Preset) => {
    if (nextPreset === 'custom') {
      update({ range: 'custom', from: range.from, to: range.to });
    } else {
      update({ range: nextPreset, from: null, to: null, bucket: null });
    }
  };
  const onCustomChange = (next: DateRange) =>
    update({ range: 'custom', from: next.from, to: next.to, bucket: null });
  const onBucketChange = (next: Bucket) => update({ bucket: next });

  const needsRange = tab !== 'outstanding';
  const guard = (node: ReactNode) =>
    valid ? (
      node
    ) : (
      <Card>
        <EmptyState
          icon={<CalendarRange aria-hidden="true" />}
          title="Choose a valid date range"
          description="Fix the dates above to run this report."
        />
      </Card>
    );

  const content = (t: ReportTab): ReactNode => {
    switch (t) {
      case 'revenue':
        return guard(<RevenueReport range={range} bucket={bucket} />);
      case 'payments':
        return guard(<PaymentsReport range={range} />);
      case 'sales':
        return guard(<SalesReport range={range} />);
      case 'team':
        return guard(<TeamReport range={range} ownOnly={!canViewAll} />);
      case 'customers':
        return guard(<CustomersReport range={range} />);
      case 'outstanding':
        return <OutstandingReport />;
    }
  };

  const items: TabItem<ReportTab>[] = tabs.map((t) => ({
    value: t,
    label: TAB_LABELS[t],
    content: content(t),
  }));

  return (
    <>
      <PageHeader
        title="Reports"
        description={
          canViewAll
            ? 'Revenue, payments, sales, team and customer reports in your shop’s time zone.'
            : 'Your hours, completed jobs and pay for a period.'
        }
      />
      <div className="flex flex-col gap-4">
        <Card padded>
          {needsRange ? (
            <RangePicker
              preset={preset}
              range={range}
              bucket={bucket}
              error={error}
              showBucket={tab === 'revenue'}
              onPresetChange={onPresetChange}
              onCustomChange={onCustomChange}
              onBucketChange={onBucketChange}
            />
          ) : (
            <p className="text-muted text-sm">
              Outstanding balances are always as of right now — no date range needed.
            </p>
          )}
        </Card>
        {tabs.length > 1 ? (
          <Tabs
            label="Reports"
            value={tab}
            onChange={(t) => update({ tab: t === tabs[0] ? null : t })}
            items={items}
          />
        ) : (
          content(tab)
        )}
      </div>
    </>
  );
}
