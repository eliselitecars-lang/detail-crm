import {
  CalendarClock,
  FileText,
  Inbox,
  MessageSquare,
  Receipt,
  TriangleAlert,
  Users,
} from 'lucide-react';
import { Link } from 'react-router';
import {
  Avatar,
  Card,
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  SectionCard,
  StatusBadge,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { formatInTz, formatLocalDate, formatTime, formatTimeRange, shopToday } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useDashboardRealtime, useDashboardSummary, useTodaySchedule } from './api';
import { RequestsCard } from './components/RequestsCard';
import { ScheduleCard } from './components/ScheduleCard';
import { StatTile } from './components/StatTile';
import { TimeClockCard } from './components/TimeClockCard';
import type { DashboardSummary, NextJob } from './summary';

function plural(n: number, one: string, many = `${one}s`) {
  return `${n.toLocaleString('en-US')} ${n === 1 ? one : many}`;
}

export default function DashboardPage() {
  const { shopId, timezone, memberId, role, shop, currency, displayName } = useShop();
  const isShopScope = useCan('reports.view');
  const summary = useDashboardSummary(shopId);
  const today = summary.data?.today ?? shopToday(timezone);
  const schedule = useTodaySchedule(shopId, timezone, today);
  useDashboardRealtime(shopId);

  const firstName = displayName.trim().split(/\s+/)[0] ?? '';

  // Technicians: only their assigned jobs (full rows) are shown.
  const scheduleQuery =
    role === 'technician'
      ? {
          ...schedule,
          data: schedule.data?.filter((j) => j.assigned_member_ids?.includes(memberId) ?? false),
        }
      : schedule;

  return (
    <>
      <PageHeader
        title="Dashboard"
        description={`${firstName ? `Hi ${firstName} — ` : ''}${formatLocalDate(today, 'EEEE, MMMM d')} at ${shop.name}`}
      />

      {summary.isPending ? (
        <Card>
          <LoadingState label="Loading your dashboard…" />
        </Card>
      ) : summary.isError ? (
        <Card>
          <ErrorState
            error={summary.error}
            onRetry={() => void summary.refetch()}
            retrying={summary.isRefetching}
          />
        </Card>
      ) : (
        <div className="flex flex-col gap-4 sm:gap-5">
          {isShopScope && summary.data.scope === 'shop' && (
            <ShopTiles data={summary.data} currency={currency} />
          )}

          <div className="grid grid-cols-1 gap-4 sm:gap-5 lg:grid-cols-3">
            <div className="flex min-w-0 flex-col gap-4 sm:gap-5 lg:col-span-2">
              <ScheduleCard
                title={role === 'technician' ? 'My jobs today' : 'Today’s schedule'}
                query={scheduleQuery}
                timezone={timezone}
                emptyText={
                  role === 'technician'
                    ? 'No jobs assigned to you today'
                    : 'Nothing scheduled today'
                }
              />
              {isShopScope && <RequestsCard shopId={shopId} timezone={timezone} />}
            </div>
            <div className="flex min-w-0 flex-col gap-4 sm:gap-5">
              <NextJobCard job={summary.data.next_job} timezone={timezone} />
              <TimeClockCard
                shopId={shopId}
                memberId={memberId}
                timezone={timezone}
                weekStart={summary.data.week_start}
                today={summary.data.today}
              />
              {isShopScope && <ClockedInCard data={summary.data} timezone={timezone} />}
            </div>
          </div>
        </div>
      )}
    </>
  );
}

function ShopTiles({ data, currency }: { data: DashboardSummary; currency: string }) {
  const money = (cents: number) => formatCents(cents, { currency });
  const revenue = data.revenue;
  const open = data.open_invoices;
  const overdue = data.overdue_invoices;
  const tips = (cents: number, count: number) =>
    `${plural(count, 'payment')}${cents > 0 ? ` · ${money(cents)} tips (not in revenue)` : ''}`;

  return (
    <section aria-label="Shop at a glance" className="flex flex-col gap-3">
      {revenue && (
        <div className="grid grid-cols-1 gap-3 min-[480px]:grid-cols-3">
          <StatTile
            label="Revenue today"
            tone="money"
            value={money(revenue.today.net_cents)}
            detail={tips(revenue.today.tips_cents, revenue.today.payments_count)}
            href="/app/payments"
          />
          <StatTile
            label="This week"
            tone="money"
            value={money(revenue.week.net_cents)}
            detail={tips(revenue.week.tips_cents, revenue.week.payments_count)}
            href="/app/payments"
          />
          <StatTile
            label="This month"
            tone="money"
            value={money(revenue.month.net_cents)}
            detail={tips(revenue.month.tips_cents, revenue.month.payments_count)}
            href="/app/reports"
          />
        </div>
      )}
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <StatTile
          label="Jobs today"
          icon={<CalendarClock />}
          value={data.jobs_today.total.toLocaleString('en-US')}
          detail={`${plural(data.jobs_this_week, 'job')} this week`}
          href="/app/calendar"
        />
        <StatTile
          label="Booking requests"
          icon={<Inbox />}
          value={(data.pending_booking_requests ?? 0).toLocaleString('en-US')}
          detail="Awaiting approval"
          href="/app/jobs?status=requested"
        />
        <StatTile
          label="Quotes out"
          icon={<FileText />}
          value={(data.quotes_awaiting_response ?? 0).toLocaleString('en-US')}
          detail="Awaiting response"
          href="/app/quotes?status=sent"
        />
        <StatTile
          label="Open invoices"
          icon={<Receipt />}
          tone={open && open.balance_cents > 0 ? 'money' : 'default'}
          value={money(open?.balance_cents ?? 0)}
          detail={plural(open?.count ?? 0, 'invoice')}
          href="/app/invoices?status=open"
        />
        <StatTile
          label="Overdue"
          icon={<TriangleAlert />}
          tone={overdue && overdue.count > 0 ? 'danger' : 'default'}
          value={money(overdue?.balance_cents ?? 0)}
          detail={plural(overdue?.count ?? 0, 'invoice')}
          href="/app/invoices?status=overdue"
        />
      </div>
      <Link
        to="/app/messages"
        className="rounded-card border-line bg-surface shadow-card hover:bg-surface-2/60 flex items-center justify-between gap-3 border px-4 py-3"
      >
        <span className="text-ink flex items-center gap-2 text-sm font-medium">
          <MessageSquare className="text-muted size-4" aria-hidden="true" />
          Messages
        </span>
        <span className="text-muted text-sm">
          {data.unread_inbound_messages
            ? `${plural(data.unread_inbound_messages, 'unread message')}`
            : 'No unread messages'}
        </span>
      </Link>
    </section>
  );
}

function NextJobCard({ job, timezone }: { job: NextJob | null; timezone: string }) {
  return (
    <SectionCard title="Next up" flush>
      {job ? (
        <Link to={`/app/jobs/${job.id}`} className="hover:bg-surface-2/60 block px-4 py-4 sm:px-5">
          <div className="flex items-start justify-between gap-2">
            <p className="text-ink text-sm font-semibold break-words">
              {job.customer_name ?? 'Customer'}
              <span className="text-muted font-normal"> · #{job.number}</span>
            </p>
            <StatusBadge kind="job" status={job.status} />
          </div>
          <p className="text-ink tabular mt-1 text-sm">
            {formatInTz(job.scheduled_start, timezone, 'EEE, MMM d')} ·{' '}
            {formatTimeRange(job.scheduled_start, job.scheduled_end, timezone)}
          </p>
          <p className="text-muted mt-0.5 text-xs">
            {[job.vehicle_label, job.location_type === 'mobile' ? 'Mobile' : 'At the shop']
              .filter(Boolean)
              .join(' · ')}
          </p>
        </Link>
      ) : (
        <EmptyState compact icon={<CalendarClock aria-hidden="true" />} title="No upcoming jobs" />
      )}
    </SectionCard>
  );
}

function ClockedInCard({ data, timezone }: { data: DashboardSummary; timezone: string }) {
  const members = data.clocked_in.members;
  return (
    <SectionCard
      title="On the clock"
      description={members.length > 0 ? plural(members.length, 'person', 'people') : undefined}
      flush
    >
      {members.length === 0 ? (
        <EmptyState compact icon={<Users aria-hidden="true" />} title="Nobody is clocked in" />
      ) : (
        <ul className="divide-line divide-y">
          {members.map((m) => (
            <li key={m.member_id} className="flex items-center gap-3 px-4 py-2.5 sm:px-5">
              <Avatar name={m.display_name} size="sm" />
              <span className="min-w-0 flex-1">
                <span className="text-ink block truncate text-sm font-medium">
                  {m.display_name}
                </span>
                <span className="text-muted block text-xs">
                  Since {formatTime(m.since, timezone)}
                  {m.job_id && (
                    <>
                      {' · '}
                      <Link
                        to={`/app/jobs/${m.job_id}`}
                        className="text-primary-ink hover:underline"
                      >
                        on a job
                      </Link>
                    </>
                  )}
                </span>
              </span>
            </li>
          ))}
        </ul>
      )}
    </SectionCard>
  );
}
