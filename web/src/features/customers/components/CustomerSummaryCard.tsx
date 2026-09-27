import type { ReactNode } from 'react';
import { ErrorState, LoadingState, SectionCard } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { cn } from '@/lib/cn';
import { formatDate } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useCustomerSummary, type CustomerSummary } from '../api';

interface TileProps {
  label: string;
  value: ReactNode;
  detail?: ReactNode;
  tone?: 'default' | 'money' | 'danger';
}

function Tile({ label, value, detail, tone = 'default' }: TileProps) {
  return (
    <div className="border-line rounded-control min-w-0 border p-3">
      <dt className="text-muted text-xs font-medium tracking-wide uppercase">{label}</dt>
      <dd
        className={cn(
          'tabular mt-1 text-lg font-semibold tracking-tight break-words',
          tone === 'money' ? 'text-money-ink' : tone === 'danger' ? 'text-danger-ink' : 'text-ink',
        )}
      >
        {value}
      </dd>
      {detail && <dd className="text-muted mt-0.5 text-xs">{detail}</dd>}
    </div>
  );
}

function plural(count: number, one: string, many: string): string {
  return `${count} ${count === 1 ? one : many}`;
}

function SummaryTiles({ summary }: { summary: CustomerSummary }) {
  const { currency, timezone } = useShop();
  const money = (value: number) => formatCents(value, { currency });
  const paidDetail = [
    summary.tips_cents > 0 ? `incl. ${money(summary.tips_cents)} tips` : null,
    summary.refunded_cents > 0 ? `${money(summary.refunded_cents)} refunded` : null,
  ]
    .filter(Boolean)
    .join(' · ');
  const overdue = summary.overdue_balance_cents > 0;
  const extras = [
    summary.open_quotes > 0 ? plural(summary.open_quotes, 'open quote', 'open quotes') : null,
    summary.active_memberships > 0
      ? plural(summary.active_memberships, 'membership', 'memberships')
      : null,
  ]
    .filter(Boolean)
    .join(' · ');

  return (
    <>
      <dl className="grid grid-cols-1 gap-3 min-[420px]:grid-cols-2 lg:grid-cols-4">
        <Tile
          label="Lifetime paid"
          tone="money"
          value={money(summary.lifetime_paid_cents)}
          detail={paidDetail || undefined}
        />
        <Tile
          label="Open balance"
          tone={overdue ? 'danger' : summary.open_balance_cents > 0 ? 'money' : 'default'}
          value={money(summary.open_balance_cents)}
          detail={overdue ? `${money(summary.overdue_balance_cents)} overdue` : undefined}
        />
        <Tile
          label="Completed jobs"
          value={summary.completed_jobs}
          detail={
            summary.first_visit_at
              ? `Since ${formatDate(summary.first_visit_at, timezone)}`
              : undefined
          }
        />
        <Tile
          label={summary.next_job_at ? 'Next job' : 'Last visit'}
          value={
            summary.next_job_at
              ? formatDate(summary.next_job_at, timezone)
              : summary.last_visit_at
                ? formatDate(summary.last_visit_at, timezone)
                : 'None yet'
          }
          detail={
            summary.next_job_at && summary.last_visit_at
              ? `Last visit ${formatDate(summary.last_visit_at, timezone)}`
              : summary.upcoming_jobs > 1
                ? plural(summary.upcoming_jobs, 'upcoming job', 'upcoming jobs')
                : undefined
          }
        />
      </dl>
      {extras && <p className="text-muted mt-3 text-sm">{extras}</p>}
    </>
  );
}

/**
 * Money and visit totals from customer_summary (server-computed). Render
 * only for owner/admin/manager: technicians are refused by the RPC.
 */
export function CustomerSummaryCard({ customerId }: { customerId: string }) {
  const { shopId } = useShop();
  const summary = useCustomerSummary(shopId, customerId);

  return (
    <SectionCard title="At a glance" level={2} className="lg:col-span-2">
      {summary.isPending ? (
        <LoadingState variant="rows" rows={2} label="Loading customer totals…" />
      ) : summary.isError ? (
        <ErrorState compact error={summary.error} onRetry={() => void summary.refetch()} />
      ) : summary.data.completed_jobs === 0 &&
        summary.data.upcoming_jobs === 0 &&
        summary.data.lifetime_paid_cents === 0 &&
        summary.data.open_balance_cents === 0 &&
        summary.data.open_quotes === 0 &&
        summary.data.active_memberships === 0 ? (
        <p className="text-muted text-sm">No jobs, quotes or payments for this customer yet.</p>
      ) : (
        <SummaryTiles summary={summary.data} />
      )}
    </SectionCard>
  );
}
