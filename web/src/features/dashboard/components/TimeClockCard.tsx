import { Clock, LogIn, LogOut } from 'lucide-react';
import { Button, ErrorState, LoadingState, SectionCard, useToast } from '@/components/ui';
import { formatRelative, formatTime, type LocalDate } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { useClockIn, useClockOut, useMyHours, useMyOpenEntries } from '../api';
import { formatDuration } from '../summary';

export interface TimeClockCardProps {
  shopId: string;
  memberId: string;
  timezone: string;
  /** Shop-local week start / today from dashboard_summary. */
  weekStart?: LocalDate;
  today?: LocalDate;
}

/** The signed-in member's own clock (clock_in / clock_out RPCs) + hours this week. */
export function TimeClockCard({
  shopId,
  memberId,
  timezone,
  weekStart,
  today,
}: TimeClockCardProps) {
  const toast = useToast();
  const entries = useMyOpenEntries(shopId, memberId);
  const hours = useMyHours(shopId, memberId, weekStart, today);
  const clockIn = useClockIn(shopId);
  const clockOut = useClockOut(shopId);
  const shift = entries.data?.find((e) => e.kind === 'shift') ?? null;

  const run = async (action: 'in' | 'out') => {
    try {
      if (action === 'in') await clockIn.mutateAsync();
      else await clockOut.mutateAsync();
      toast.success(action === 'in' ? 'Clocked in' : 'Clocked out');
    } catch (error) {
      toast.error(toAppError(error).message);
    }
  };

  return (
    <SectionCard title="My time clock">
      {entries.isPending ? (
        <LoadingState label="Loading your clock…" className="py-6" />
      ) : entries.isError ? (
        <ErrorState compact error={entries.error} onRetry={() => void entries.refetch()} />
      ) : (
        <div className="flex flex-col gap-4">
          <div className="flex items-center gap-3">
            <span
              className={
                shift
                  ? 'bg-success-soft text-success-ink flex size-10 items-center justify-center rounded-full'
                  : 'bg-surface-2 text-muted flex size-10 items-center justify-center rounded-full'
              }
            >
              <Clock className="size-5" aria-hidden="true" />
            </span>
            <div aria-live="polite">
              <p className="text-ink text-sm font-semibold">
                {shift ? 'You’re clocked in' : 'You’re clocked out'}
              </p>
              {shift && (
                <p className="text-muted text-xs">
                  Since {formatTime(shift.clock_in, timezone)} ({formatRelative(shift.clock_in)})
                </p>
              )}
            </div>
          </div>
          {shift ? (
            <Button
              variant="secondary"
              fullWidth
              loading={clockOut.isPending}
              leadingIcon={<LogOut className="size-4" aria-hidden="true" />}
              onClick={() => void run('out')}
            >
              Clock out
            </Button>
          ) : (
            <Button
              fullWidth
              loading={clockIn.isPending}
              leadingIcon={<LogIn className="size-4" aria-hidden="true" />}
              onClick={() => void run('in')}
            >
              Clock in
            </Button>
          )}
          <div className="border-line flex items-baseline justify-between border-t pt-3">
            <span className="text-muted text-sm">Hours this week</span>
            <span className="text-ink tabular text-sm font-semibold">
              {hours.isPending ? '…' : hours.isError ? '—' : formatDuration(hours.data)}
            </span>
          </div>
        </div>
      )}
    </SectionCard>
  );
}
