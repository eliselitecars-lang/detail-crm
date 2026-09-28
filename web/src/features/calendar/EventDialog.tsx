import { useState } from 'react';
import {
  Button,
  Checkbox,
  Combobox,
  ConfirmDialog,
  DateInput,
  Dialog,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  RadioGroup,
  Select,
  Textarea,
  TimeInput,
  useToast,
} from '@/components/ui';
import type { Json } from '@/lib/database.types';
import {
  addLocalDays,
  isLocalDate,
  localDaysBetween,
  shopToday,
  utcToShopLocal,
  WEEKDAY_NAMES,
} from '@/lib/dates';
import { useDebouncedValue } from '@/lib/useDebouncedValue';
import { localWeekday } from '@/features/jobs/series';
import {
  blockToFormInput,
  describeRecurrence,
  readRecurrence,
} from '@/features/settings/blockedTimes';
import { blockedTimeSchema, type BlockedTimeFormInput } from '@/features/settings/schemas';
import { useShop } from '@/features/shop/shopContext';
import { useTeam } from '@/features/jobs/api';
import { customerName } from '@/features/jobs/model';
import { useCustomer, useCustomerSearch, type CustomerOption } from '@/features/jobs/newJobApi';
import {
  useCalendarEvent,
  useCreateCalendarEvent,
  useDeleteCalendarEvent,
  useSplitCalendarEvent,
  useUpdateCalendarEvent,
  type CalendarEventRow,
  type CalendarEventValues,
} from './api';
import { EVENT_KIND_LABELS, EVENT_KINDS, type EventKind } from './model';

/** What the page opens: a new event (optionally on a picked slot) or an occurrence. */
export type EventDialogTarget =
  | { mode: 'new'; start?: { date: string; time: string }; end?: { date: string; time: string } }
  | { mode: 'edit'; blockId: string; occurrenceStart: string };

type Scope = 'all' | 'following';

const KIND_HELP: Record<EventKind, string> = {
  closed: 'The whole shop is closed: nothing can be booked online.',
  time_off: 'A team member is away.',
  meeting: 'A meeting, training or other busy time.',
  consultation: 'A call or visit with a customer.',
  reminder: 'A note on the calendar, optionally about a customer.',
  other: 'Anything else.',
};

const WITH_CUSTOMER: readonly EventKind[] = ['consultation', 'reminder'];
const REPEATS = [
  { value: '', label: 'Does not repeat' },
  { value: 'day', label: 'Daily' },
  { value: 'week', label: 'Weekly' },
  { value: 'month', label: 'Monthly' },
] as const;

interface FormState extends BlockedTimeFormInput {
  customerId: string;
  color: string;
}

function initialForm(
  target: EventDialogTarget,
  row: CalendarEventRow | undefined,
  tz: string,
): FormState {
  if (target.mode === 'new' || !row) {
    const base = blockToFormInput(null, tz);
    const today = shopToday(tz);
    const start = target.mode === 'new' ? target.start : undefined;
    const end = target.mode === 'new' ? target.end : undefined;
    return {
      ...base,
      kind: 'meeting',
      allDay: false,
      startDate: start?.date ?? today,
      startTime: start?.time ?? '09:00',
      endDate: end?.date ?? start?.date ?? today,
      endTime: end?.time ?? '10:00',
      affectsCapacity: false,
      customerId: '',
      color: '',
    };
  }
  const base = blockToFormInput(row, tz);
  // show the occurrence that was opened, not the series' first date
  const occurrence = utcToShopLocal(target.occurrenceStart, tz).date;
  const shift = localDaysBetween(base.startDate, occurrence);
  return {
    ...base,
    startDate: occurrence,
    endDate: addLocalDays(base.endDate, shift),
    customerId: row.customer_id ?? '',
    color: row.color ?? '',
  };
}

/** The original rule ended the day before `occurrenceDate` (count rules become until rules). */
function endedBefore(recurrence: Json | null, occurrenceDate: string): Json {
  const rule = readRecurrence(recurrence) ?? { freq: 'day' as const };
  const { count: _count, ...rest } = rule;
  void _count;
  return { ...rest, until_date: addLocalDays(occurrenceDate, -1) };
}

export interface EventDialogProps {
  target: EventDialogTarget;
  onClose: () => void;
}

/**
 * New / edit calendar event (blocked_times, P-17): kind, member (time off),
 * customer (consultations, reminders), time, repeat, whether it takes online
 * booking capacity, and a colour. A repeating event is changed or deleted
 * for every occurrence, or from the opened occurrence on.
 */
export function EventDialog({ target, onClose }: EventDialogProps) {
  const row = useCalendarEvent(target.mode === 'edit' ? target.blockId : null);
  if (target.mode === 'edit' && !row.data) {
    return (
      <Dialog open onClose={onClose} title="Event" size="sm">
        {row.isError ? (
          <ErrorState compact error={row.error} onRetry={() => void row.refetch()} />
        ) : (
          <LoadingState label="Loading event…" />
        )}
      </Dialog>
    );
  }
  return <EventForm target={target} row={row.data} onClose={onClose} />;
}

function EventForm({
  target,
  row,
  onClose,
}: {
  target: EventDialogTarget;
  row: CalendarEventRow | undefined;
  onClose: () => void;
}) {
  const { timezone } = useShop();
  const toast = useToast();
  const team = useTeam();
  const create = useCreateCalendarEvent();
  const update = useUpdateCalendarEvent();
  const split = useSplitCalendarEvent();
  const remove = useDeleteCalendarEvent();
  const [form, setForm] = useState<FormState>(() => initialForm(target, row, timezone));
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [scope, setScope] = useState<Scope>('all');
  const [deleting, setDeleting] = useState(false);
  const [deleteScope, setDeleteScope] = useState<Scope>('all');
  const [query, setQuery] = useState('');
  const search = useCustomerSearch(useDebouncedValue(query, 250));
  const linked = useCustomer(form.customerId || null);
  const set = (patch: Partial<FormState>) => setForm((f) => ({ ...f, ...patch }));

  const editing = target.mode === 'edit' && row !== undefined;
  const rule = editing ? readRecurrence(row.recurrence) : null;
  const originalDate = editing ? utcToShopLocal(row.starts_at, timezone).date : '';
  const occurrenceDate =
    target.mode === 'edit' ? utcToShopLocal(target.occurrenceStart, timezone).date : '';
  const firstOccurrence = !rule || occurrenceDate <= originalDate;
  const canSplit = rule !== null && !firstOccurrence && !rule.count;
  const kind = form.kind;
  const busy = create.isPending || update.isPending || split.isPending;
  const members = (team.data ?? []).filter((m) => m.active || m.memberId === form.memberId);
  const customer: CustomerOption | null = form.customerId ? (linked.data ?? null) : null;

  const values = (input: BlockedTimeFormInput): CalendarEventValues | null => {
    const parsed = blockedTimeSchema(timezone).safeParse(input);
    if (!parsed.success) {
      const next: Record<string, string> = {};
      for (const issue of parsed.error.issues) {
        const key = String(issue.path[0] ?? 'form');
        next[key] ??= issue.message;
      }
      setErrors(next);
      return null;
    }
    const v = parsed.data;
    return {
      kind: v.kind,
      member_id: v.member_id,
      customer_id: WITH_CUSTOMER.includes(v.kind) && form.customerId ? form.customerId : null,
      title: v.title,
      reason: v.reason,
      starts_at: v.starts_at,
      ends_at: v.ends_at,
      affects_capacity: v.affects_capacity,
      color: kind === 'closed' || !form.color ? null : form.color,
      recurrence: v.recurrence as Json | null,
    };
  };

  const save = async () => {
    setErrors({});
    try {
      if (!editing) {
        const v = values(form);
        if (!v) return;
        await create.mutateAsync(v);
        toast.success('Event added');
      } else if (rule && scope === 'following' && canSplit) {
        const v = values(form);
        if (!v) return;
        await split.mutateAsync({
          id: row.id,
          endRecurrence: endedBefore(row.recurrence, occurrenceDate),
          values: v,
        });
        toast.success('Event changed from this date on');
      } else {
        // Every occurrence: move the series by as many days as this one moved.
        const moved = localDaysBetween(occurrenceDate || form.startDate, form.startDate);
        const startDate = rule ? addLocalDays(originalDate, moved) : form.startDate;
        const v = values({
          ...form,
          startDate,
          endDate: addLocalDays(form.endDate, localDaysBetween(form.startDate, startDate)),
        });
        if (!v) return;
        await update.mutateAsync({ id: row.id, values: v });
        toast.success('Event saved');
      }
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  const confirmDelete = async () => {
    if (!editing) return;
    try {
      await remove.mutateAsync(
        rule && deleteScope === 'following' && !firstOccurrence
          ? { id: row.id, endRecurrence: endedBefore(row.recurrence, occurrenceDate) }
          : { id: row.id },
      );
      toast.success('Event deleted');
      setDeleting(false);
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  const repeatText = describeRecurrence(rule);

  return (
    <>
      <Dialog
        open={!deleting}
        onClose={onClose}
        title={editing ? 'Edit event' : 'New event'}
        description={`Times are in the shop’s time zone (${timezone}).`}
        size="lg"
        dismissible={!busy}
        footer={
          <>
            {editing && (
              <Button
                variant="ghost"
                className="sm:mr-auto"
                disabled={busy}
                onClick={() => {
                  setDeleteScope('all');
                  setDeleting(true);
                }}
              >
                Delete
              </Button>
            )}
            <Button variant="secondary" onClick={onClose} disabled={busy}>
              Cancel
            </Button>
            <Button loading={busy} onClick={() => void save()}>
              {editing ? 'Save' : 'Add event'}
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-4">
          {rule && (
            <div className="bg-surface-2 rounded-control flex flex-col gap-2 px-3 py-2 text-sm">
              <p className="text-ink">Repeats: {repeatText}</p>
              <RadioGroup<Scope>
                label="Change"
                orientation="horizontal"
                value={canSplit ? scope : 'all'}
                onChange={setScope}
                options={[
                  { value: 'all', label: 'Every occurrence' },
                  {
                    value: 'following',
                    label: 'This and later ones',
                    disabled: !canSplit,
                    ...(rule.count && !firstOccurrence
                      ? { description: 'Not for repeats that end after a number of times.' }
                      : {}),
                  },
                ]}
              />
            </div>
          )}
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <FormField label="Kind" help={KIND_HELP[kind]}>
              <Select
                value={form.kind}
                onChange={(e) => {
                  const next = EVENT_KINDS.find((k) => k === e.target.value) ?? 'other';
                  set({
                    kind: next,
                    affectsCapacity:
                      next === 'closed' || next === 'time_off' ? true : form.affectsCapacity,
                    ...(WITH_CUSTOMER.includes(next) ? {} : { customerId: '' }),
                  });
                }}
                options={EVENT_KINDS.map((k) => ({ value: k, label: EVENT_KIND_LABELS[k] }))}
              />
            </FormField>
            <FormField label="Title" error={errors.title}>
              <Input
                value={form.title ?? ''}
                maxLength={120}
                placeholder={EVENT_KIND_LABELS[kind]}
                onChange={(e) => set({ title: e.target.value })}
              />
            </FormField>
            {kind !== 'closed' && (
              <FormField
                label="Team member"
                required={kind === 'time_off'}
                error={errors.memberId}
                help={kind === 'time_off' ? undefined : 'Leave empty for the whole shop.'}
              >
                <Select
                  value={form.memberId}
                  onChange={(e) => set({ memberId: e.target.value })}
                  options={[
                    { value: '', label: kind === 'time_off' ? 'Choose…' : 'Whole shop' },
                    ...members.map((m) => ({ value: m.memberId, label: m.name })),
                  ]}
                />
              </FormField>
            )}
            {WITH_CUSTOMER.includes(kind) && (
              <FormField label="Customer" help="Optional. Only managers see who it is.">
                <Combobox<CustomerOption>
                  value={customer}
                  onChange={(c) => set({ customerId: c?.id ?? '' })}
                  options={search.data ?? []}
                  loading={search.isFetching || (form.customerId !== '' && linked.isPending)}
                  onQueryChange={setQuery}
                  getOptionValue={(c) => c.id}
                  getOptionLabel={(c) => customerName(c)}
                  placeholder="Search customers…"
                />
              </FormField>
            )}
          </div>
          <Checkbox
            label="All day"
            checked={form.allDay}
            onChange={(e) => set({ allDay: e.target.checked })}
          />
          <div className="grid grid-cols-2 gap-3">
            <FormField label="Start date" error={errors.startDate}>
              <DateInput
                value={form.startDate}
                onChange={(e) => {
                  const date = e.target.value;
                  // keep the length when the start moves
                  const span = localDaysBetween(form.startDate, form.endDate);
                  set({
                    startDate: date,
                    ...(date && span >= 0 ? { endDate: addLocalDays(date, span) } : {}),
                  });
                }}
              />
            </FormField>
            {!form.allDay && (
              <FormField label="Start time" error={errors.startTime}>
                <TimeInput
                  value={form.startTime}
                  onChange={(e) => set({ startTime: e.target.value })}
                />
              </FormField>
            )}
            <FormField label={form.allDay ? 'Last day' : 'End date'} error={errors.endDate}>
              <DateInput value={form.endDate} onChange={(e) => set({ endDate: e.target.value })} />
            </FormField>
            {!form.allDay && (
              <FormField label="End time" error={errors.endTime}>
                <TimeInput
                  value={form.endTime}
                  onChange={(e) => set({ endTime: e.target.value })}
                />
              </FormField>
            )}
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <FormField label="Repeat">
              <Select
                value={form.repeat}
                onChange={(e) => {
                  const repeat = REPEATS.find((r) => r.value === e.target.value)?.value ?? '';
                  // weekly: start with the event's own weekday
                  const weekdays =
                    repeat === 'week' &&
                    (form.weekdays ?? []).length === 0 &&
                    isLocalDate(form.startDate)
                      ? [localWeekday(form.startDate)]
                      : form.weekdays;
                  set({ repeat, weekdays });
                }}
                options={REPEATS.map((r) => ({ value: r.value, label: r.label }))}
              />
            </FormField>
            {form.repeat !== '' && (
              <FormField
                label="Every"
                error={errors.interval}
                help={form.repeat === 'day' ? 'days' : form.repeat === 'week' ? 'weeks' : 'months'}
              >
                <Input
                  inputMode="numeric"
                  value={form.interval}
                  onChange={(e) => set({ interval: e.target.value })}
                />
              </FormField>
            )}
          </div>
          {form.repeat === 'week' && (
            <fieldset>
              <legend className="text-ink mb-1.5 text-sm font-medium">On</legend>
              <div className="flex flex-wrap gap-x-4 gap-y-2">
                {[1, 2, 3, 4, 5, 6, 0].map((d) => (
                  <Checkbox
                    key={d}
                    label={WEEKDAY_NAMES[d]?.slice(0, 3)}
                    aria-label={WEEKDAY_NAMES[d]}
                    checked={(form.weekdays ?? []).includes(d)}
                    onChange={(e) =>
                      set({
                        weekdays: e.target.checked
                          ? [...(form.weekdays ?? []), d]
                          : (form.weekdays ?? []).filter((x) => x !== d),
                      })
                    }
                  />
                ))}
              </div>
              {errors.weekdays && (
                <p role="alert" className="text-danger-ink mt-1 text-xs font-medium">
                  {errors.weekdays}
                </p>
              )}
            </fieldset>
          )}
          {form.repeat !== '' && (
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <FormField label="Ends">
                <Select
                  value={form.repeatEnd}
                  onChange={(e) =>
                    set({
                      repeatEnd:
                        e.target.value === 'until' || e.target.value === 'count'
                          ? e.target.value
                          : 'never',
                    })
                  }
                  options={[
                    { value: 'never', label: 'Never' },
                    { value: 'until', label: 'On a date' },
                    { value: 'count', label: 'After a number of times' },
                  ]}
                />
              </FormField>
              {form.repeatEnd === 'until' && (
                <FormField label="Last date" error={errors.untilDate}>
                  <DateInput
                    value={form.untilDate}
                    onChange={(e) => set({ untilDate: e.target.value })}
                  />
                </FormField>
              )}
              {form.repeatEnd === 'count' && (
                <FormField label="Times" error={errors.count}>
                  <Input
                    inputMode="numeric"
                    value={form.count}
                    onChange={(e) => set({ count: e.target.value })}
                  />
                </FormField>
              )}
            </div>
          )}
          {kind !== 'closed' && kind !== 'time_off' && (
            <Checkbox
              label="Blocks online booking capacity"
              description="Counts as a busy slot (the whole shop) or makes the team member unavailable."
              checked={form.affectsCapacity}
              onChange={(e) => set({ affectsCapacity: e.target.checked })}
            />
          )}
          {kind !== 'closed' && (
            <div className="flex flex-wrap items-end gap-3">
              <FormField label="Colour" help="Optional. Shown on the calendar.">
                <input
                  type="color"
                  value={form.color || '#6b7280'}
                  onChange={(e) => set({ color: e.target.value })}
                  className="border-line-strong rounded-control h-9 w-14 cursor-pointer border bg-transparent p-1"
                />
              </FormField>
              {form.color && (
                <Button size="sm" variant="ghost" onClick={() => set({ color: '' })}>
                  No colour
                </Button>
              )}
            </div>
          )}
          <FormField label="Note" error={errors.reason} help="Only your team sees this.">
            <Textarea
              rows={2}
              maxLength={500}
              value={form.reason ?? ''}
              onChange={(e) => set({ reason: e.target.value })}
            />
          </FormField>
        </div>
      </Dialog>
      <ConfirmDialog
        open={deleting}
        onClose={() => setDeleting(false)}
        onConfirm={confirmDelete}
        tone="danger"
        loading={remove.isPending}
        title="Delete this event?"
        description={
          rule
            ? 'It repeats. Choose which occurrences to delete.'
            : 'It is removed from the calendar.'
        }
        confirmLabel="Delete"
      >
        {rule && !firstOccurrence && (
          <RadioGroup<Scope>
            label="Delete"
            hideLabel
            value={deleteScope}
            onChange={setDeleteScope}
            options={[
              { value: 'following', label: 'This and later occurrences' },
              { value: 'all', label: 'Every occurrence' },
            ]}
          />
        )}
      </ConfirmDialog>
    </>
  );
}
