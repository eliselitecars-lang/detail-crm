import { Clock, LogIn, LogOut } from 'lucide-react';
import { Badge, Button, ErrorState, LoadingState, SectionCard, useToast } from '@/components/ui';
import { formatDateTime, formatTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useAssignments, useTeam, type JobDetail } from '../../api';
import { useJobClock, useJobTime } from '../../fieldApi';
import { formatDuration } from '../../model';

export function TimeCard({ job }: { job: JobDetail }) {
  const { timezone, memberId } = useShop();
  const toast = useToast();
  const time = useJobTime(job.id);
  const team = useTeam();
  const assignments = useAssignments(job.id);
  const clock = useJobClock(job.id);
  const names = new Map((team.data ?? []).map((m) => [m.memberId, m.name]));
  const assigned = (assignments.data ?? []).some((a) => a.member_id === memberId);
  const closed = ['completed', 'cancelled', 'no_show'].includes(job.status);

  const mine = time.data?.myOpenJobEntry ?? null;
  const onThisJob = mine?.job_id === job.id;

  const act = async (action: 'in' | 'out') => {
    try {
      await clock.mutateAsync(action);
      toast.success(action === 'in' ? 'Clocked in on this job' : 'Clocked out');
    } catch (error) {
      toast.error(error);
    }
  };

  const entries = time.data?.entries ?? [];
  const open = entries.filter((e) => e.clock_out === null);

  return (
    <SectionCard title="Time" level={3}>
      {time.isPending ? (
        <LoadingState label="Loading time…" />
      ) : time.isError ? (
        <ErrorState compact error={time.error} onRetry={() => void time.refetch()} />
      ) : (
        <div className="flex flex-col gap-3">
          {open.length > 0 ? (
            <p className="flex flex-wrap items-center gap-2 text-sm">
              <Clock className="text-success size-4" aria-hidden="true" />
              On the clock: {open.map((e) => names.get(e.member_id) ?? 'Team member').join(', ')}
            </p>
          ) : (
            <p className="text-muted text-sm">Nobody is clocked in on this job.</p>
          )}
          {assigned &&
            (onThisJob ? (
              <Button
                variant="secondary"
                loading={clock.isPending}
                leadingIcon={<LogOut className="size-4" aria-hidden="true" />}
                onClick={() => void act('out')}
              >
                Clock out
              </Button>
            ) : mine ? (
              <p className="text-muted text-sm">
                You’re clocked in on another job. Clock out there first.
              </p>
            ) : (
              !closed && (
                <Button
                  loading={clock.isPending}
                  leadingIcon={<LogIn className="size-4" aria-hidden="true" />}
                  onClick={() => void act('in')}
                >
                  Clock in on this job
                </Button>
              )
            ))}
          {entries.length > 0 && (
            <ul className="border-line flex flex-col gap-2 border-t pt-3 text-sm">
              {entries.map((e) => (
                <li key={e.id} className="flex flex-wrap justify-between gap-x-3">
                  <span className="text-ink">{names.get(e.member_id) ?? 'Team member'}</span>
                  <span className="text-muted tabular-nums">
                    {formatDateTime(e.clock_in, timezone)} –{' '}
                    {e.clock_out ? (
                      <>
                        {formatTime(e.clock_out, timezone)} ·{' '}
                        {formatDuration(
                          Math.round((Date.parse(e.clock_out) - Date.parse(e.clock_in)) / 60_000),
                        )}
                      </>
                    ) : (
                      <Badge tone="success">Now</Badge>
                    )}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </SectionCard>
  );
}
