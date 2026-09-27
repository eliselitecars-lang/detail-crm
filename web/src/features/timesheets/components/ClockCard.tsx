import { LogIn, LogOut, Timer } from 'lucide-react';
import { Badge, Button, ErrorState, SectionCard, Skeleton } from '@/components/ui';
import { formatTime } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { useShop } from '@/features/shop/shopContext';
import { useClock, useMyOpenEntries } from '../api';
import { formatClock } from '../model';
import { useNow } from '../useNow';

/** The signed-in member's own time clock with a live running timer. */
export function ClockCard() {
  const { timezone } = useShop();
  const open = useMyOpenEntries();
  const { clockIn, clockOut } = useClock();
  const shift = open.data?.find((e) => e.kind === 'shift') ?? null;
  const job = open.data?.find((e) => e.kind === 'job') ?? null;
  const now = useNow(1000, shift !== null || job !== null);
  const error = clockIn.error ?? clockOut.error;

  let body;
  if (open.isPending) body = <Skeleton className="h-16 w-full" />;
  else if (open.error)
    body = (
      <ErrorState
        error={open.error}
        title="Couldn’t load your time clock"
        onRetry={() => void open.refetch()}
        retrying={open.isRefetching}
        compact
      />
    );
  else
    body = (
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-3">
          <span
            className={
              shift
                ? 'bg-success-soft text-success-ink rounded-full p-2.5'
                : 'bg-surface-2 text-muted rounded-full p-2.5'
            }
          >
            <Timer className="size-6" aria-hidden="true" />
          </span>
          <div>
            {shift ? (
              <>
                <p className="text-muted text-sm">
                  On the clock since {formatTime(shift.clock_in, timezone)}
                </p>
                <p
                  className="text-ink text-2xl font-semibold tabular-nums"
                  role="timer"
                  aria-label="Time on the clock"
                >
                  {formatClock(now - new Date(shift.clock_in).getTime())}
                </p>
              </>
            ) : (
              <>
                <p className="text-ink text-base font-semibold">You’re clocked out</p>
                <p className="text-muted text-sm">Clock in when you start your shift.</p>
              </>
            )}
            {job && (
              <p className="mt-1 flex flex-wrap items-center gap-2 text-sm">
                <Badge tone="info" dot>
                  {job.job ? `Job #${job.job.number}` : 'Job'}
                </Badge>
                <span className="text-muted tabular-nums">
                  {formatClock(now - new Date(job.clock_in).getTime())} since{' '}
                  {formatTime(job.clock_in, timezone)}
                </span>
              </p>
            )}
          </div>
        </div>
        <div className="flex flex-col gap-2 sm:flex-row">
          {job && (
            <Button
              variant="secondary"
              loading={clockOut.isPending && clockOut.variables === 'job'}
              disabled={clockIn.isPending || clockOut.isPending}
              onClick={() => clockOut.mutate('job')}
            >
              Stop job clock
            </Button>
          )}
          {shift ? (
            <Button
              size="lg"
              variant="secondary"
              leadingIcon={<LogOut />}
              loading={clockOut.isPending && clockOut.variables === 'shift'}
              disabled={clockIn.isPending || clockOut.isPending}
              onClick={() => clockOut.mutate('shift')}
            >
              Clock out
            </Button>
          ) : (
            <Button
              size="lg"
              leadingIcon={<LogIn />}
              loading={clockIn.isPending}
              disabled={clockOut.isPending}
              onClick={() => clockIn.mutate()}
            >
              Clock in
            </Button>
          )}
        </div>
      </div>
    );

  return (
    <SectionCard title="My time clock">
      {body}
      {error && (
        <p role="alert" className="text-danger-ink mt-3 text-sm">
          {errorMessage(error)}
        </p>
      )}
    </SectionCard>
  );
}
