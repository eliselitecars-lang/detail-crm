import { Plus, Trash2 } from 'lucide-react';
import { Button, Switch, TimeInput } from '@/components/ui';
import { cn } from '@/lib/cn';
import { WEEKDAY_NAMES } from '@/lib/dates';
import type { DayHours, HoursInterval } from '../businessHours';

/**
 * Below `sm` two inputs share ~270px, less than Chrome needs for "08:00 AM"
 * plus its desktop clock icon, so the icon is hidden there (touch browsers
 * open their native picker on tap; typing and arrow keys still work).
 */
const TIME_INPUT_CLASS = 'min-w-0 sm:w-32 max-sm:[&::-webkit-calendar-picker-indicator]:hidden';

export interface BusinessHoursEditorProps {
  value: DayHours[];
  onChange: (value: DayHours[]) => void;
  /** Per-weekday errors from validateWeek(). */
  errors?: Record<number, string>;
  disabled?: boolean;
}

/** Weekly opening hours with multiple intervals per day (shop-local times). */
export function BusinessHoursEditor({
  value,
  onChange,
  errors = {},
  disabled = false,
}: BusinessHoursEditorProps) {
  const update = (weekday: number, patch: (day: DayHours) => DayHours) =>
    onChange(value.map((day) => (day.weekday === weekday ? patch(day) : day)));

  const setInterval = (weekday: number, index: number, next: Partial<HoursInterval>) =>
    update(weekday, (day) => ({
      ...day,
      intervals: day.intervals.map((iv, i) => (i === index ? { ...iv, ...next } : iv)),
    }));

  // Show Monday first; weekday numbers stay 0 = Sunday.
  const ordered = [...value].sort((a, b) => ((a.weekday + 6) % 7) - ((b.weekday + 6) % 7));

  return (
    <div className="divide-line rounded-card border-line divide-y border">
      {ordered.map((day) => {
        const name = WEEKDAY_NAMES[day.weekday] ?? `Day ${day.weekday}`;
        const error = errors[day.weekday];
        return (
          // min-w-0: a fieldset's default min-inline-size is min-content, which
          // would let the time inputs push the row past the card on phones.
          <fieldset
            key={day.weekday}
            className="flex min-w-0 flex-col gap-2 px-3 py-3 sm:flex-row sm:items-start sm:gap-4"
          >
            <legend className="sr-only">{name} hours</legend>
            <div className="flex w-full items-center justify-between gap-3 sm:w-40 sm:shrink-0 sm:pt-1.5">
              <span className="text-ink text-sm font-medium" aria-hidden="true">
                {name}
              </span>
              <Switch
                aria-label={`Open on ${name}`}
                checked={day.open}
                disabled={disabled}
                onCheckedChange={(open) => update(day.weekday, (d) => ({ ...d, open }))}
              />
            </div>
            <div className="flex min-w-0 flex-1 flex-col items-start gap-2">
              {day.open ? (
                <>
                  {day.intervals.map((interval, index) => (
                    // Phones: the time pair takes the full row (so "08:00 AM" is
                    // never clipped) and "Remove" wraps below it. sm+: one line
                    // with an icon-only remove button.
                    <div
                      key={index}
                      className="flex w-full min-w-0 flex-wrap items-center justify-end gap-2 sm:flex-nowrap sm:justify-start"
                    >
                      <div className="grid min-w-0 flex-[1_1_100%] grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-1.5 sm:flex sm:flex-none sm:gap-2">
                        <TimeInput
                          aria-label={`${name} opens at`}
                          value={interval.opensAt}
                          disabled={disabled}
                          aria-invalid={error ? true : undefined}
                          onChange={(event) =>
                            setInterval(day.weekday, index, { opensAt: event.target.value })
                          }
                          className={TIME_INPUT_CLASS}
                        />
                        <span className="text-muted text-sm" aria-hidden="true">
                          to
                        </span>
                        <TimeInput
                          aria-label={`${name} closes at`}
                          value={interval.closesAt}
                          disabled={disabled}
                          aria-invalid={error ? true : undefined}
                          onChange={(event) =>
                            setInterval(day.weekday, index, { closesAt: event.target.value })
                          }
                          className={TIME_INPUT_CLASS}
                        />
                      </div>
                      {day.intervals.length > 1 ? (
                        <button
                          type="button"
                          title={`Remove ${name} hours ${interval.opensAt}–${interval.closesAt}`}
                          disabled={disabled}
                          onClick={() =>
                            update(day.weekday, (d) => ({
                              ...d,
                              intervals: d.intervals.filter((_, i) => i !== index),
                            }))
                          }
                          className="rounded-control text-danger-ink hover:bg-danger-soft focus-visible:outline-primary inline-flex h-8 shrink-0 items-center justify-center gap-1.5 px-2 text-xs font-medium transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 disabled:cursor-not-allowed disabled:opacity-55 sm:w-8 sm:px-0"
                        >
                          <Trash2 className="size-4 sm:size-[18px]" aria-hidden="true" />
                          <span className="sm:sr-only">Remove</span>
                          <span className="sr-only">
                            {' '}
                            {name} hours {interval.opensAt}–{interval.closesAt}
                          </span>
                        </button>
                      ) : null}
                    </div>
                  ))}
                  <Button
                    variant="ghost"
                    size="sm"
                    leadingIcon={<Plus className="size-4" aria-hidden="true" />}
                    disabled={disabled}
                    onClick={() =>
                      update(day.weekday, (d) => ({
                        ...d,
                        intervals: [...d.intervals, { opensAt: '13:00', closesAt: '17:00' }],
                      }))
                    }
                  >
                    Add time range<span className="sr-only"> for {name}</span>
                  </Button>
                </>
              ) : (
                <p className={cn('text-muted text-sm sm:pt-1.5')}>Closed</p>
              )}
              {error && (
                <p role="alert" className="text-danger-ink text-xs font-medium">
                  {error}
                </p>
              )}
            </div>
          </fieldset>
        );
      })}
    </div>
  );
}
