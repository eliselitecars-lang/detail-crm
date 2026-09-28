import { zodResolver } from '@hookform/resolvers/zod';
import { useState } from 'react';
import { Controller, useForm, useWatch } from 'react-hook-form';
import type { z } from 'zod';
import {
  Button,
  Combobox,
  DateInput,
  Dialog,
  FormField,
  RadioGroup,
  Select,
  Textarea,
  TimeInput,
  useToast,
} from '@/components/ui';
import { shopToday } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { useShop } from '@/features/shop/shopContext';
import { useJobSearch, useSaveEntry, type JobHit, type SaveEntryInput } from '../api';
import {
  clockOrderError,
  entryEditPatch,
  entryFormSchema,
  entryFormTimes,
  entryFormToWrite,
  geoStamp,
  type TimeEntry,
  type TimeEntryKind,
} from '../model';
import { GeoLinks } from './GeoLinks';

type FormInput = z.input<typeof entryFormSchema>;
type FormOutput = z.output<typeof entryFormSchema>;

export interface EntryDialogProps {
  /** Entry to edit; omit to add a manual entry. */
  entry?: TimeEntry;
  members: readonly { member_id: string; display_name: string; active: boolean }[];
  /** Pre-selected member for new entries. */
  defaultMemberId?: string;
  onClose: () => void;
}

/** Managers+: add or edit a time entry in the shop's time zone. */
export function EntryDialog({ entry, members, defaultMemberId, onClose }: EntryDialogProps) {
  const { timezone } = useShop();
  const toast = useToast();
  const save = useSaveEntry();
  const [jobQuery, setJobQuery] = useState('');
  const jobs = useJobSearch(jobQuery);
  const [job, setJob] = useState<JobHit | null>(
    entry?.job_id
      ? { id: entry.job_id, label: entry.job ? `Job #${entry.job.number}` : 'Job' }
      : null,
  );

  const initialTimes = entry ? entryFormTimes(entry, timezone) : null;
  const today = shopToday(timezone);
  const {
    register,
    control,
    handleSubmit,
    setValue,
    setError,
    formState: { errors },
  } = useForm<FormInput, unknown, FormOutput>({
    resolver: zodResolver(entryFormSchema),
    defaultValues: {
      memberId: entry?.member_id ?? defaultMemberId ?? '',
      kind: entry?.kind ?? 'shift',
      jobId: entry?.job_id ?? '',
      inDate: initialTimes?.inDate ?? today,
      inTime: initialTimes?.inTime ?? '',
      outDate: initialTimes ? initialTimes.outDate : today,
      outTime: initialTimes?.outTime ?? '',
      notes: entry?.notes ?? '',
    },
  });
  const kind = useWatch({ control, name: 'kind' });

  const onSubmit = handleSubmit(async (values) => {
    // Edits send only the changed columns: untouched clock times keep their
    // stored instants (seconds, DST occurrence) — see entryEditPatch.
    let input: SaveEntryInput;
    let clockIn: string;
    let clockOut: string | null;
    if (entry) {
      const patch = entryEditPatch(values, timezone, entry);
      input = { id: entry.id, patch };
      clockIn = patch.clock_in ?? entry.clock_in;
      clockOut = patch.clock_out !== undefined ? patch.clock_out : entry.clock_out;
    } else {
      const write = entryFormToWrite(values, timezone);
      input = { values: write };
      clockIn = write.clock_in;
      clockOut = write.clock_out;
    }
    const orderError = clockOrderError(clockIn, clockOut);
    if (orderError) {
      setError('outTime', { type: 'custom', message: orderError }, { shouldFocus: true });
      return;
    }
    try {
      await save.mutateAsync(input);
      toast.success(entry ? 'Entry updated' : 'Entry added');
      onClose();
    } catch {
      // shown via save.error (e.g. overlaps with an existing entry)
    }
  });

  const memberOptions = members
    .filter((m) => m.active || m.member_id === entry?.member_id)
    .map((m) => ({ value: m.member_id, label: m.display_name }));

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      size="lg"
      title={entry ? 'Edit time entry' : 'Add time entry'}
      description={`Times are in your shop’s time zone (${timezone}).`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form="entry-form" loading={save.isPending}>
            {entry ? 'Save changes' : 'Add entry'}
          </Button>
        </>
      }
    >
      <form
        id="entry-form"
        noValidate
        onSubmit={(event) => void onSubmit(event)}
        className="flex flex-col gap-4"
      >
        {save.error && (
          <p
            role="alert"
            className="border-danger/30 bg-danger-soft text-danger-ink rounded-control border px-3 py-2 text-sm"
          >
            {errorMessage(save.error)}
          </p>
        )}
        {entry && (geoStamp(entry, 'in') || geoStamp(entry, 'out')) && (
          <div className="bg-surface-2 rounded-control flex flex-col gap-1 px-3 py-2">
            <p className="text-muted text-xs">
              Recorded by the iPhone app when the member clocked in or out. Locations can’t be
              edited.
            </p>
            <GeoLinks entry={entry} />
          </div>
        )}
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField label="Team member" error={errors.memberId?.message} required>
            <Select
              {...register('memberId')}
              disabled={entry !== undefined}
              placeholder="Choose…"
              options={memberOptions}
            />
          </FormField>
          <Controller
            control={control}
            name="kind"
            render={({ field }) => (
              <RadioGroup<TimeEntryKind>
                label="Type"
                orientation="horizontal"
                value={field.value}
                disabled={entry !== undefined}
                onChange={(next) => {
                  field.onChange(next);
                  if (next === 'shift') {
                    setJob(null);
                    setValue('jobId', '');
                  }
                }}
                options={[
                  { value: 'shift', label: 'Shift' },
                  { value: 'job', label: 'Job time' },
                ]}
              />
            )}
          />
        </div>
        {kind === 'job' && (
          <FormField label="Job" error={errors.jobId?.message} required>
            <Combobox<JobHit>
              value={job}
              onChange={(next) => {
                setJob(next);
                setValue('jobId', next?.id ?? '', { shouldValidate: true });
              }}
              options={jobs.data ?? []}
              onQueryChange={setJobQuery}
              getOptionValue={(j) => j.id}
              getOptionLabel={(j) => j.label}
              loading={jobs.isFetching}
              placeholder="Search by job number or customer"
              emptyText={jobQuery.trim() ? 'No matching jobs' : 'Type to search'}
            />
          </FormField>
        )}
        <fieldset className="grid gap-4 sm:grid-cols-2">
          <legend className="text-ink mb-2 text-sm font-medium">Clock in</legend>
          <FormField label="Date" error={errors.inDate?.message} required>
            <DateInput {...register('inDate')} />
          </FormField>
          <FormField label="Time" error={errors.inTime?.message} required>
            <TimeInput step={60} {...register('inTime')} />
          </FormField>
        </fieldset>
        <fieldset className="grid gap-4 sm:grid-cols-2">
          <legend className="text-ink mb-2 text-sm font-medium">
            Clock out <span className="text-muted font-normal">(empty = still running)</span>
          </legend>
          <FormField label="Date" error={errors.outDate?.message}>
            <DateInput {...register('outDate')} />
          </FormField>
          <FormField label="Time" error={errors.outTime?.message}>
            <TimeInput step={60} {...register('outTime')} />
          </FormField>
        </fieldset>
        <FormField label="Notes" error={errors.notes?.message}>
          <Textarea rows={2} {...register('notes')} maxLength={2000} />
        </FormField>
      </form>
    </Dialog>
  );
}
