import { CalendarRange } from 'lucide-react';
import type { ReactNode } from 'react';
import { useSearchParams } from 'react-router';
import { Card, EmptyState, PageHeader, Tabs, type TabItem } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { CustomersReport } from './components/CustomersReport';
import { GiftCardsReport } from './components/GiftCardsReport';
import { OutstandingReport } from './components/OutstandingReport';
import { PaymentsReport } from './components/PaymentsReport';
import { JobProfitReport, ServiceProfitReport } from './components/ProfitReports';
import { RangePicker } from './components/RangePicker';
import { RevenueReport } from './components/RevenueReport';
import { LeadSourcesReport, QuoteConversionReport } from './components/SalesFunnelReports';
import { SalesReport } from './components/SalesReport';
import { TeamReport } from './components/TeamReport';
import { readParams, type Bucket, type DateRange, type Preset } from './ranges';
import { useShopDayClock } from './useShopDayClock';

const ALL_TABS = [
  'revenue',
  'payments',
  'sales',
  'team',
  'customers',
  'lead_sources',
  'quotes',
  'job_profit',
  'service_profit',
  'gift_cards',
  'outstanding',
] as const;
type ReportTab = (typeof ALL_TABS)[number];

const TAB_LABELS: Record<ReportTab, string> = {
  revenue: 'Revenue',
  payments: 'Payments',
  sales: 'Sales by service',
  team: 'Team',
  customers: 'Customers',
  lead_sources: 'Lead sources',
  quotes: 'Quote conversion',
  job_profit: 'Job profit',
  service_profit: 'Service profit',
  gift_cards: 'Gift cards',
  outstanding: 'Outstanding',
};

export default function ReportsPage() {
  const { timezone } = useShop();
  // Technicians only get their own team row (report_team); the other
  // reports are manager+ on the server too.
  const canViewAll = useCan('reports.view');
  const [params, setParams] = useSearchParams();
  // Presets (Today / This week / …) roll over at the shop's midnight.
  const { now, refresh: refreshNow } = useShopDayClock(timezone);
  const { preset, range, bucket, valid, error } = readParams(params, timezone, now);

  const tabs: readonly ReportTab[] = canViewAll ? ALL_TABS : ['team'];
  const rawTab = params.get('tab');
  const tab: ReportTab = tabs.find((t) => t === rawTab) ?? tabs[0] ?? 'team';

  // Functional update: quick successive edits (From then To) each apply to
  // the latest URL, never to a stale render's params.
  const update = (patch: Record<string, string | null>) => {
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        for (const [key, value] of Object.entries(patch)) {
          if (value === null) next.delete(key);
          else next.set(key, value);
        }
        return next;
      },
      { replace: true },
    );
  };

  const onPresetChange = (nextPreset: Preset) => {
    refreshNow();
    if (nextPreset === 'custom') {
      update({ range: 'custom', from: range.from, to: range.to });
    } else {
      update({ range: nextPreset, from: null, to: null, bucket: null });
    }
  };
  const onCustomChange = (next: Partial<DateRange>) =>
    update({ range: 'custom', ...next, bucket: null });
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
      case 'lead_sources':
        return guard(<LeadSourcesReport range={range} />);
      case 'quotes':
        return guard(<QuoteConversionReport range={range} />);
      case 'job_profit':
        return guard(<JobProfitReport range={range} />);
      case 'service_profit':
        return guard(<ServiceProfitReport range={range} />);
      case 'gift_cards':
        return guard(<GiftCardsReport range={range} />);
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
            ? 'Revenue, payments, sales, team, customers, leads, quotes, profit and gift cards in your shop’s time zone.'
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
