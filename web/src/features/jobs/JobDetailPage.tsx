import { useParams } from 'react-router';
import { Card, ErrorState, LoadingState, PageHeader, StatusBadge } from '@/components/ui';
import { formatInTz, formatTimeRange } from '@/lib/dates';
import { isNonRetryable } from '@/lib/errors';
import { useRealtime } from '@/lib/useRealtime';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { jobKeys, useJob, type JobDetail } from './api';
import { ActivityCard, NotesCard } from './components/detail/ActivityNotesCards';
import { AssignmentsCard } from './components/detail/AssignmentsCard';
import { ChecklistCard } from './components/detail/ChecklistCard';
import { FormsCard } from './components/detail/FormsCard';
import { InspectionsCard } from './components/detail/InspectionsCard';
import { LineItemsCard } from './components/detail/LineItemsCard';
import { MessagesCard } from './components/detail/MessagesCard';
import { MoneyCard } from './components/detail/MoneyCard';
import { CustomerCard, VehicleCard } from './components/detail/PeopleCards';
import { PhotosCard } from './components/detail/PhotosCard';
import { ScheduleCard } from './components/detail/ScheduleCard';
import { StatusControl } from './components/detail/StatusControl';
import { TimeCard } from './components/detail/TimeCard';
import { customerName, jobNumberLabel } from './model';

export default function JobDetailPage() {
  const { jobId = '' } = useParams();
  const { shopId } = useShop();
  const job = useJob(jobId);

  // Jobs, payments, messages and time entries change under us (other staff,
  // webhooks, the phone app): refresh this job's panels when they do.
  const detailKey = [jobKeys.detail(shopId, jobId)];
  useRealtime({ table: 'jobs', shopId, filter: `id=eq.${jobId}` });
  useRealtime({ table: 'payments', shopId, filter: `job_id=eq.${jobId}`, invalidate: detailKey });
  useRealtime({ table: 'messages', shopId, filter: `job_id=eq.${jobId}`, invalidate: detailKey });
  useRealtime({ table: 'time_entries', shopId, filter: `job_id=eq.${jobId}`, invalidate: detailKey });

  if (job.isPending) {
    return (
      <>
        <PageHeader title="Job" back={{ to: '/app/jobs', label: 'Jobs' }} />
        <Card>
          <LoadingState label="Loading job…" />
        </Card>
      </>
    );
  }
  if (job.isError) {
    return (
      <>
        <PageHeader title="Job" back={{ to: '/app/jobs', label: 'Jobs' }} />
        <Card>
          <ErrorState
            title="Couldn’t load this job"
            error={job.error}
            {...(isNonRetryable(job.error)
              ? {}
              : { onRetry: () => void job.refetch(), retrying: job.isRefetching })}
          />
        </Card>
      </>
    );
  }
  return <JobView key={job.data.id} job={job.data} />;
}

function JobView({ job }: { job: JobDetail }) {
  const { timezone } = useShop();
  const canSeeMoney = useCan('invoices.viewAssigned');

  return (
    <>
      <PageHeader
        title={jobNumberLabel(job.number)}
        back={{ to: '/app/jobs', label: 'Jobs' }}
        meta={
          <span className="flex flex-wrap items-center gap-2">
            <StatusBadge kind="job" status={job.status} />
            <span className="text-muted text-sm">
              {customerName(job.customer)}
              {job.scheduled_start && job.scheduled_end
                ? ` · ${formatInTz(job.scheduled_start, timezone, 'EEE, MMM d')} · ${formatTimeRange(job.scheduled_start, job.scheduled_end, timezone)}`
                : ' · Not scheduled'}
            </span>
          </span>
        }
      />
      <Card padded className="mb-4">
        <StatusControl job={job} />
      </Card>
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="flex min-w-0 flex-col gap-4 lg:col-span-2">
          <ScheduleCard job={job} />
          <LineItemsCard job={job} />
          <ChecklistCard jobId={job.id} />
          <PhotosCard jobId={job.id} />
          <InspectionsCard job={job} />
          <FormsCard job={job} />
        </div>
        <div className="flex min-w-0 flex-col gap-4">
          <CustomerCard job={job} />
          <VehicleCard job={job} />
          {canSeeMoney && <MoneyCard job={job} />}
          <AssignmentsCard jobId={job.id} />
          <TimeCard job={job} />
          <MessagesCard job={job} />
          <NotesCard job={job} />
          <ActivityCard job={job} />
        </div>
      </div>
    </>
  );
}
