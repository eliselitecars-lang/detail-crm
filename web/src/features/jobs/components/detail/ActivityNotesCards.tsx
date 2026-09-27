import { useState } from 'react';
import { Button, FormField, SectionCard, Textarea, useToast } from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useUpdateJob, type JobDetail } from '../../api';

const SOURCE_LABELS: Record<string, string> = {
  staff: 'Created by staff',
  online_booking: 'Booked online',
  quote: 'Created from a quote',
  membership: 'Created from a membership',
};

/** Status timestamps stamped by the jobs status trigger. */
export function ActivityCard({ job }: { job: JobDetail }) {
  const { timezone } = useShop();
  const events = [
    { key: 'created', label: SOURCE_LABELS[job.source] ?? 'Created', at: job.created_at },
    { key: 'confirmed', label: 'Confirmed', at: job.confirmed_at },
    { key: 'reminder', label: 'Reminder sent', at: job.reminder_sent_at },
    { key: 'en_route', label: 'On the way', at: job.en_route_at },
    { key: 'started', label: 'Work started', at: job.started_at },
    { key: 'completed', label: 'Completed', at: job.completed_at },
    { key: 'review', label: 'Review requested', at: job.review_requested_at },
    {
      key: 'cancelled',
      label: job.cancel_reason ? `Cancelled — ${job.cancel_reason}` : 'Cancelled',
      at: job.cancelled_at,
    },
  ]
    .filter((e): e is { key: string; label: string; at: string } => e.at !== null)
    .sort((a, b) => a.at.localeCompare(b.at));

  return (
    <SectionCard title="Activity" level={3}>
      <ol className="border-line relative flex flex-col gap-3 border-l pl-4">
        {events.map((e) => (
          <li key={e.key} className="relative text-sm">
            <span
              aria-hidden="true"
              className="bg-primary absolute top-1.5 -left-[21px] size-2 rounded-full"
            />
            <p className="text-ink">{e.label}</p>
            <p className="text-muted text-xs">{formatDateTime(e.at, timezone)}</p>
          </li>
        ))}
      </ol>
    </SectionCard>
  );
}

/**
 * Customer-visible notes (managers+) and internal notes (any staff on the
 * job — technicians may change only status and internal notes).
 */
export function NotesCard({ job }: { job: JobDetail }) {
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const update = useUpdateJob(job.id);
  const [notes, setNotes] = useState(job.notes ?? '');
  const [internal, setInternal] = useState(job.internal_notes ?? '');
  const dirty =
    internal !== (job.internal_notes ?? '') || (canManage && notes !== (job.notes ?? ''));

  const save = async () => {
    try {
      await update.mutateAsync({
        internal_notes: internal.trim() || null,
        ...(canManage ? { notes: notes.trim() || null } : {}),
      });
      toast.success('Notes saved');
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard title="Notes" level={3}>
      <div className="flex flex-col gap-3">
        {canManage ? (
          <FormField
            label="Notes for the customer"
            help="Shown on the customer’s booking and documents."
          >
            <Textarea
              rows={3}
              maxLength={20000}
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
            />
          </FormField>
        ) : (
          job.notes && (
            <div>
              <p className="text-muted text-xs font-semibold uppercase">Customer notes</p>
              <p className="text-ink text-sm whitespace-pre-line">{job.notes}</p>
            </div>
          )
        )}
        <FormField label="Internal notes" help="Only your team sees these.">
          <Textarea
            rows={3}
            maxLength={20000}
            value={internal}
            onChange={(e) => setInternal(e.target.value)}
          />
        </FormField>
        <div>
          <Button
            size="sm"
            loading={update.isPending}
            disabled={!dirty}
            onClick={() => void save()}
          >
            Save notes
          </Button>
        </div>
      </div>
    </SectionCard>
  );
}
