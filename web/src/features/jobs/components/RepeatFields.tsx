import { useId } from 'react';
import {
  DateInput,
  ErrorState,
  FormField,
  Input,
  RadioGroup,
  Select,
  Spinner,
} from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatInTz, formatTimeRange, WEEKDAY_NAMES } from '@/lib/dates';
import { useDebouncedValue } from '@/lib/useDebouncedValue';
import {
  effectiveMonthMode,
  monthOptions,
  SERIES_LIMITS,
  WEEKDAY_ORDER,
  WEEKDAY_SHORT,
  type CurrentMonthRule,
  type MonthMode,
  type RepeatDraft,
  type RepeatEnd,
  type SeriesFreq,
} from '../series';
import { useSeriesPreview } from '../seriesApi';

export interface RepeatFieldsProps {
  draft: RepeatDraft;
  onChange: (next: RepeatDraft) => void;
  /** The first visit's (or the edited visit's) date: month options come from it. */
  anchorDate: string;
  /** Editing a monthly series: its own rule, offered (and kept) as is. */
  currentMonthRule?: CurrentMonthRule | null;
  disabled?: boolean;
}

const INTERVALS = Array.from({ length: SERIES_LIMITS.intervalMax }, (_, i) => i + 1);

/** The repeat rule: every N weeks (weekday chips) or months, and when it ends. */
export function RepeatFields({
  draft,
  onChange,
  anchorDate,
  currentMonthRule = null,
  disabled = false,
}: RepeatFieldsProps) {
  const weekdaysId = useId();
  const set = (patch: Partial<RepeatDraft>) => onChange({ ...draft, ...patch });
  const n = Number(draft.interval) || 1;
  // the same fallback repeatRuleFields saves, so the checked option is the one sent
  const monthMode = effectiveMonthMode(draft.monthMode, anchorDate, currentMonthRule);

  return (
    <div className="flex flex-col gap-4">
      <div className="grid grid-cols-2 gap-3">
        <FormField label="Repeat every">
          <Select
            value={draft.interval}
            disabled={disabled}
            onChange={(e) => set({ interval: e.target.value })}
            options={INTERVALS.map((i) => ({ value: String(i), label: String(i) }))}
          />
        </FormField>
        <FormField label="Unit">
          <Select
            value={draft.freq}
            disabled={disabled}
            onChange={(e) => set({ freq: e.target.value === 'month' ? 'month' : 'week' })}
            options={
              [
                { value: 'week', label: n === 1 ? 'week' : 'weeks' },
                { value: 'month', label: n === 1 ? 'month' : 'months' },
              ] satisfies { value: SeriesFreq; label: string }[]
            }
          />
        </FormField>
      </div>
      {draft.freq === 'week' ? (
        <fieldset disabled={disabled}>
          <legend id={weekdaysId} className="text-ink mb-1.5 text-sm font-medium">
            On
          </legend>
          <div className="flex flex-wrap gap-1.5">
            {WEEKDAY_ORDER.map((d) => {
              const on = draft.weekdays.includes(d);
              return (
                <button
                  key={d}
                  type="button"
                  aria-pressed={on}
                  aria-label={WEEKDAY_NAMES[d]}
                  onClick={() =>
                    set({
                      weekdays: on ? draft.weekdays.filter((x) => x !== d) : [...draft.weekdays, d],
                    })
                  }
                  className={cn(
                    'rounded-full border px-3 py-1 text-xs font-medium',
                    on
                      ? 'border-primary bg-primary-soft text-primary-ink'
                      : 'border-line-strong text-muted hover:text-ink',
                  )}
                >
                  {WEEKDAY_SHORT[d]}
                </button>
              );
            })}
          </div>
        </fieldset>
      ) : (
        <RadioGroup<MonthMode>
          label="On"
          value={monthMode}
          disabled={disabled}
          onChange={(monthMode) => set({ monthMode })}
          options={monthOptions(anchorDate, currentMonthRule)}
        />
      )}
      <RadioGroup<RepeatEnd>
        label="Ends"
        value={draft.end}
        disabled={disabled}
        onChange={(end) => set({ end })}
        options={[
          {
            value: 'never',
            label: 'Keeps going',
            description: 'Visits are added about 90 days ahead.',
          },
          { value: 'until', label: 'On a date' },
          { value: 'count', label: 'After a number of visits' },
        ]}
      />
      {draft.end === 'until' && (
        <FormField label="Last possible visit date">
          <DateInput
            value={draft.untilDate}
            min={anchorDate}
            disabled={disabled}
            onChange={(e) => set({ untilDate: e.target.value })}
          />
        </FormField>
      )}
      {draft.end === 'count' && (
        <FormField label="Number of visits" help="Counting the first one (up to 500).">
          <Input
            inputMode="numeric"
            value={draft.count}
            disabled={disabled}
            onChange={(e) => set({ count: e.target.value })}
          />
        </FormField>
      )}
    </div>
  );
}

/** Live list of the first visits the rule creates (job_series_preview). */
export function SeriesPreview({
  payload,
  timezone,
}: {
  payload: Record<string, unknown> | null;
  timezone: string;
}) {
  const debounced = useDebouncedValue(payload, 400);
  const preview = useSeriesPreview(debounced);
  if (payload === null) return null;
  return (
    <div className="bg-surface-2 rounded-control flex flex-col gap-1.5 p-3" aria-live="polite">
      <p className="text-ink flex items-center gap-2 text-sm font-medium">
        First visits
        {preview.isFetching && <Spinner className="text-muted size-3.5" />}
      </p>
      {preview.isError ? (
        <ErrorState compact error={preview.error} onRetry={() => void preview.refetch()} />
      ) : preview.data && preview.data.length > 0 ? (
        <ol className="text-muted flex flex-col gap-0.5 text-sm">
          {preview.data.map((o) => (
            <li key={o.seq}>
              <span className="text-ink">
                {formatInTz(o.starts_at, timezone, 'EEE, MMM d, yyyy')}
              </span>
              {' · '}
              {formatTimeRange(o.starts_at, o.ends_at, timezone)}
            </li>
          ))}
        </ol>
      ) : preview.isSuccess ? (
        <p className="text-muted text-sm">This rule creates no visits.</p>
      ) : (
        <p className="text-muted text-sm">Working out the dates…</p>
      )}
    </div>
  );
}
