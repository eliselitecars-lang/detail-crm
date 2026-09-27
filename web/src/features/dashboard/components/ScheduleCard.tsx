import { CalendarDays, MapPin } from 'lucide-react';
import { Link } from 'react-router';
import { EmptyState, ErrorState, LoadingState, SectionCard, StatusBadge } from '@/components/ui';
import { formatTimeRange } from '@/lib/dates';
import type { ScheduleJob } from '../api';
import { servicesFromTitle } from '../summary';

interface ScheduleQuery {
  isPending: boolean;
  isError: boolean;
  error: unknown;
  data: ScheduleJob[] | undefined;
  refetch: () => Promise<unknown>;
}

export function ScheduleCard({
  title,
  query,
  timezone,
  emptyText,
}: {
  title: string;
  query: ScheduleQuery;
  timezone: string;
  emptyText: string;
}) {
  return (
    <SectionCard
      title={title}
      flush
      actions={
        <Link to="/app/calendar" className="text-primary-ink text-sm font-medium hover:underline">
          Calendar
        </Link>
      }
    >
      {query.isPending ? (
        <LoadingState variant="rows" rows={3} label="Loading today’s schedule…" />
      ) : query.isError || !query.data ? (
        <ErrorState compact error={query.error} onRetry={() => void query.refetch()} />
      ) : query.data.length === 0 ? (
        <EmptyState compact icon={<CalendarDays aria-hidden="true" />} title={emptyText} />
      ) : (
        <ul className="divide-line divide-y">
          {query.data.map((job) => (
            <li key={job.id}>
              <Link
                to={`/app/jobs/${job.id}`}
                className="hover:bg-surface-2/60 flex flex-col gap-1 px-4 py-3 sm:flex-row sm:items-center sm:gap-4 sm:px-5"
              >
                <span className="text-ink tabular w-40 shrink-0 text-sm font-medium">
                  {formatTimeRange(job.starts_at, job.ends_at, timezone)}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="text-ink block text-sm font-medium break-words">
                    {job.customer_name ?? 'Customer'}
                    {job.job_number !== null && (
                      <span className="text-muted font-normal"> · #{job.job_number}</span>
                    )}
                  </span>
                  <span className="text-muted block text-xs break-words">
                    {[job.vehicle_label, servicesFromTitle(job.title)]
                      .filter(Boolean)
                      .join(' · ') || '—'}
                  </span>
                  {job.location_type === 'mobile' && job.service_address && (
                    <span className="text-muted mt-0.5 flex items-center gap-1 text-xs break-words">
                      <MapPin className="size-3 shrink-0" aria-hidden="true" />
                      {job.service_address}
                    </span>
                  )}
                </span>
                {job.status && (
                  <span className="self-start sm:self-auto">
                    <StatusBadge kind="job" status={job.status} />
                  </span>
                )}
              </Link>
            </li>
          ))}
        </ul>
      )}
    </SectionCard>
  );
}
