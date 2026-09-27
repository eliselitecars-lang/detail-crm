import { CalendarX2, ChevronLeft, ChevronRight, Globe } from 'lucide-react';
import { Button, EmptyState, ErrorState, LoadingState } from '@/components/ui';
import { cn } from '@/lib/cn';
import { addLocalDays, formatInTz, formatLocalDate, formatTime } from '@/lib/dates';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { timeZoneName } from '@/features/public-docs/shared/format';
import { useAvailableSlots } from '../api';
import {
  canGoToNextWeek,
  canGoToPreviousWeek,
  groupSlotsByDay,
  lastBookableDate,
  previousWeekStart,
  weekWindow,
  type SlotChoice,
} from '../model';
import { StepFrame } from './StepFrame';

export function TimeStep({
  slug,
  timeZone,
  maxDaysAhead,
  itemIds,
  categoryId,
  weekStart,
  onWeekChange,
  slot,
  onSelect,
  notice,
  onBack,
  onContinue,
}: {
  slug: string;
  timeZone: string;
  maxDaysAhead: number | null;
  /** Services + add-ons. */
  itemIds: string[];
  categoryId: string;
  weekStart: string;
  onWeekChange: (start: string) => void;
  slot: SlotChoice | null;
  onSelect: (slot: SlotChoice) => void;
  /** e.g. "that time was just taken". */
  notice: string | null;
  onBack: () => void;
  onContinue: () => void;
}) {
  const range = weekWindow(weekStart);
  const slots = useAvailableSlots(slug, {
    serviceIds: itemIds,
    vehicleCategoryId: categoryId,
    from: range.from,
    to: range.to,
  });
  const lastDate = lastBookableDate(timeZone, maxDaysAhead);
  const days = slots.data ? groupSlotsByDay(slots.data, timeZone, range) : [];
  const anySlots = days.some((d) => d.slots.length > 0);
  const zone = timeZoneName(timeZone, new Date(`${range.from}T12:00:00Z`));
  const hasNext = canGoToNextWeek(weekStart, lastDate);

  return (
    <StepFrame
      title="Pick a date and time"
      description={
        <span className="inline-flex items-center gap-1.5">
          <Globe className="size-3.5 shrink-0" aria-hidden="true" />
          Times are shown in the shop’s time zone: {zone} ({timeZone}).
        </span>
      }
      onBack={onBack}
      onContinue={onContinue}
      continueDisabled={slot === null}
    >
      {notice && <Banner tone="warning" title={notice} />}
      <div className="flex items-center justify-between gap-2">
        <Button
          variant="secondary"
          size="sm"
          onClick={() => onWeekChange(previousWeekStart(weekStart, timeZone))}
          disabled={!canGoToPreviousWeek(weekStart, timeZone)}
          leadingIcon={<ChevronLeft className="size-4" aria-hidden="true" />}
          aria-label="Previous week"
        >
          <span className="max-sm:sr-only">Previous</span>
        </Button>
        <p className="text-ink text-center text-sm font-semibold" aria-live="polite">
          {formatLocalDate(range.from, 'MMM d')} – {formatLocalDate(range.to, 'MMM d, yyyy')}
        </p>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => onWeekChange(addLocalDays(weekStart, 7))}
          disabled={!hasNext}
          trailingIcon={<ChevronRight className="size-4" aria-hidden="true" />}
          aria-label="Next week"
        >
          <span className="max-sm:sr-only">Next</span>
        </Button>
      </div>

      {slots.isPending ? (
        <LoadingState label="Finding open times…" />
      ) : slots.isError ? (
        <ErrorState
          compact
          error={slots.error}
          title="Couldn’t load open times"
          onRetry={() => void slots.refetch()}
          retrying={slots.isFetching}
        />
      ) : !anySlots ? (
        <EmptyState
          compact
          icon={<CalendarX2 aria-hidden="true" />}
          title="No open times this week"
          description={hasNext ? 'Try the next week.' : 'Please call the shop to find a time.'}
          {...(hasNext
            ? {
                action: (
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => onWeekChange(addLocalDays(weekStart, 7))}
                  >
                    Next week
                  </Button>
                ),
              }
            : {})}
        />
      ) : (
        <div
          className={cn('flex flex-col gap-4', slots.isFetching && 'opacity-60')}
          aria-busy={slots.isFetching}
        >
          {days
            .filter((day) => day.slots.length > 0)
            .map((day) => {
              const headingId = `day-${day.date}`;
              return (
                <section key={day.date} aria-labelledby={headingId} className="flex flex-col gap-2">
                  <h3 id={headingId} className="text-ink text-sm font-semibold">
                    {formatLocalDate(day.date, 'EEEE, MMMM d')}
                  </h3>
                  <div className="grid grid-cols-3 gap-2 sm:grid-cols-5 md:grid-cols-6">
                    {day.slots.map((s) => {
                      const selected = slot?.startsAt === s.startsAt;
                      return (
                        <button
                          key={s.startsAt}
                          type="button"
                          aria-pressed={selected}
                          onClick={() => onSelect(s)}
                          className={cn(
                            'rounded-control h-10 border text-sm font-medium tabular-nums transition-colors',
                            'focus-visible:outline-primary focus-visible:outline-2 focus-visible:outline-offset-2',
                            selected
                              ? 'border-brand bg-brand text-brand-fg'
                              : 'border-line-strong bg-surface text-ink hover:bg-surface-2',
                          )}
                        >
                          {formatTime(s.startsAt, timeZone)}
                          <span className="sr-only">
                            {' '}
                            on {formatInTz(s.startsAt, timeZone, 'EEEE, MMMM d')}
                          </span>
                        </button>
                      );
                    })}
                  </div>
                </section>
              );
            })}
        </div>
      )}
    </StepFrame>
  );
}
