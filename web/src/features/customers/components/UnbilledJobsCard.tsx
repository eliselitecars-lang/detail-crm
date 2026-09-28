import { Receipt } from 'lucide-react';
import { useState } from 'react';
import { useNavigate } from 'react-router';
import {
  Button,
  Checkbox,
  ErrorState,
  LoadingState,
  SectionCard,
  StatusBadge,
  useToast,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import {
  MAX_GROUPED_JOBS,
  useCreateInvoiceFromJobs,
  useUnbilledJobs,
  type UnbilledJob,
} from '@/features/invoices/api';
import { zJobStatus } from '@/features/public-docs/shared/schemas';

/**
 * Jobs of the customer that no live invoice bills yet (fleets, dealers):
 * pick two or more and bill them on one invoice (create_invoice_from_jobs).
 * Shown only when there is something to bill together.
 */
export function UnbilledJobsCard({ customerId }: { customerId: string }) {
  const { timezone, currency } = useShop();
  const toast = useToast();
  const navigate = useNavigate();
  const jobs = useUnbilledJobs(customerId, true);
  const create = useCreateInvoiceFromJobs(customerId);
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set());

  if (jobs.isPending) {
    return (
      <SectionCard title="Unbilled jobs" className="lg:col-span-2">
        <LoadingState variant="rows" rows={2} label="Loading unbilled jobs…" />
      </SectionCard>
    );
  }
  if (jobs.isError) {
    return (
      <SectionCard title="Unbilled jobs" className="lg:col-span-2">
        <ErrorState compact error={jobs.error} onRetry={() => void jobs.refetch()} />
      </SectionCard>
    );
  }
  // One job is billed from its own page; grouping needs at least two.
  if (jobs.data.length < 2) return null;

  const rows = jobs.data;
  const count = selected.size;
  const allSelected = count === Math.min(rows.length, MAX_GROUPED_JOBS);
  const toggle = (id: string, on: boolean) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (on && next.size < MAX_GROUPED_JOBS) next.add(id);
      else next.delete(id);
      return next;
    });

  const submit = async () => {
    try {
      const invoice = await create.mutateAsync({ jobIds: [...selected] });
      toast.success(`Invoice #${invoice.number} created for ${count} jobs`);
      await navigate(`/app/invoices/${invoice.id}`);
    } catch (error) {
      toast.error(error);
    }
  };

  const when = (job: UnbilledJob) =>
    job.completed_at
      ? `Completed ${formatDate(job.completed_at, timezone)}`
      : job.scheduled_start
        ? formatDate(job.scheduled_start, timezone)
        : 'Not scheduled';

  return (
    <SectionCard
      title="Unbilled jobs"
      description="Bill several jobs on one invoice, grouped by job and vehicle."
      className="lg:col-span-2"
      flush
      actions={
        <Button
          size="sm"
          variant="secondary"
          onClick={() =>
            setSelected(
              allSelected
                ? new Set()
                : new Set(rows.slice(0, MAX_GROUPED_JOBS).map((j) => j.job_id)),
            )
          }
        >
          {allSelected ? 'Clear' : 'Select all'}
        </Button>
      }
      footer={
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p className="text-muted text-xs" aria-live="polite">
            {count === 0
              ? 'Choose at least two jobs.'
              : `${count} job${count === 1 ? '' : 's'} selected`}
          </p>
          <Button
            variant="money"
            size="sm"
            leadingIcon={<Receipt className="size-4" aria-hidden="true" />}
            disabled={count < 2}
            loading={create.isPending}
            onClick={() => void submit()}
          >
            Create invoice
          </Button>
        </div>
      }
    >
      <ul className="divide-line divide-y" aria-label="Unbilled jobs">
        {rows.map((job) => {
          const status = zJobStatus.safeParse(job.status);
          return (
            <li key={job.job_id} className="flex items-start gap-3 px-4 py-3">
              <Checkbox
                className="min-w-0 flex-1"
                checked={selected.has(job.job_id)}
                onChange={(event) => toggle(job.job_id, event.target.checked)}
                label={<span className="font-medium">Job #{job.number}</span>}
                description={[job.vehicle_label, when(job)].filter(Boolean).join(' · ')}
              />
              <div className="flex shrink-0 flex-col items-end gap-1">
                <span className="text-ink text-sm font-medium tabular-nums">
                  {formatCents(job.total_cents, { currency })}
                </span>
                {job.paid_cents > 0 && (
                  <span className="text-muted text-xs tabular-nums">
                    {formatCents(job.paid_cents, { currency })} paid
                  </span>
                )}
                {status.success && <StatusBadge kind="job" status={status.data} />}
              </div>
            </li>
          );
        })}
      </ul>
    </SectionCard>
  );
}
