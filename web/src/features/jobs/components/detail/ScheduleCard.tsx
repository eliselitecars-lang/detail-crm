import { Pencil, Repeat } from 'lucide-react';
import { useState } from 'react';
import {
  Button,
  DateInput,
  Dialog,
  ErrorState,
  FormField,
  Input,
  KeyValueList,
  LoadingState,
  RadioGroup,
  SectionCard,
  Select,
  TimeInput,
  useToast,
} from '@/components/ui';
import { formatInTz, formatTimeRange, utcToShopLocal } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useResources, useUpdateJob, type JobDetail, type JobPatch } from '../../api';
import { formatDuration, scheduleToUtc, type LocationType } from '../../model';
import {
  describeSeries,
  jobLocalDate,
  spanMinutes,
  SERIES_LIMITS,
  visitLabel,
  type SeriesRow,
} from '../../series';
import {
  describeSeriesEdit,
  useFollowSeriesEdit,
  useJobSeries,
  useUpdateSeries,
} from '../../seriesApi';
import { LocationLine } from './PeopleCards';
import { EditRepeatDialog, EndSeriesDialog } from './SeriesDialogs';

export function ScheduleCard({ job }: { job: JobDetail }) {
  const { timezone } = useShop();
  const canManage = useCan('jobs.manage');
  const resources = useResources();
  const series = useJobSeries(job.series_id, canManage);
  const [editing, setEditing] = useState(false);
  const [seriesDialog, setSeriesDialog] = useState<'repeat' | 'end' | null>(null);
  const resource = resources.data?.find((r) => r.id === job.resource_id);
  const liveSeries = series.data?.active ? series.data : null;
  // Until the series row is known, a save could only apply to this visit,
  // and the server then detaches it from the repeat for good (0051
  // jobs_series_guard), so the edit waits for it (or its error + retry).
  const seriesStatus: SeriesStatus =
    !job.series_id || !canManage
      ? 'none'
      : series.isPending
        ? 'loading'
        : series.isError
          ? 'error'
          : 'ready';
  const retrySeries = () => void series.refetch();

  const minutes =
    job.scheduled_start && job.scheduled_end
      ? Math.round((Date.parse(job.scheduled_end) - Date.parse(job.scheduled_start)) / 60_000)
      : null;

  return (
    <SectionCard
      title="Schedule & location"
      level={3}
      actions={
        canManage ? (
          <Button
            size="sm"
            variant="ghost"
            leadingIcon={<Pencil className="size-4" aria-hidden="true" />}
            onClick={() => setEditing(true)}
          >
            Edit
          </Button>
        ) : undefined
      }
    >
      {job.series_id && (
        <SeriesBanner
          job={job}
          series={series.data ?? null}
          loading={seriesStatus === 'loading'}
          error={seriesStatus === 'error' ? series.error : null}
          onRetry={retrySeries}
          retrying={series.isFetching}
          onEditRepeat={liveSeries ? () => setSeriesDialog('repeat') : undefined}
          onEnd={liveSeries ? () => setSeriesDialog('end') : undefined}
        />
      )}
      <KeyValueList
        items={[
          {
            key: 'when',
            label: 'When',
            value:
              job.scheduled_start && job.scheduled_end ? (
                <span>
                  {formatInTz(job.scheduled_start, timezone, 'EEE, MMM d, yyyy')}
                  <span className="text-muted block text-xs">
                    {formatTimeRange(job.scheduled_start, job.scheduled_end, timezone)}
                    {minutes !== null ? ` · ${formatDuration(minutes)}` : ''}
                  </span>
                </span>
              ) : (
                'Not scheduled yet'
              ),
          },
          { key: 'where', label: 'Where', value: <LocationLine job={job} /> },
          {
            key: 'resource',
            label: 'Bay / van',
            value: resource ? resource.name : job.resource_id ? 'Unavailable' : 'None',
          },
        ]}
      />
      {editing && (
        <ScheduleDialog
          job={job}
          series={liveSeries}
          seriesStatus={seriesStatus}
          seriesError={series.error}
          onRetrySeries={retrySeries}
          retryingSeries={series.isFetching}
          onClose={() => setEditing(false)}
          resources={(resources.data ?? []).filter(
            (r) => (r.active && !r.archived_at) || r.id === job.resource_id,
          )}
        />
      )}
      {seriesDialog === 'repeat' && liveSeries && (
        <EditRepeatDialog job={job} series={liveSeries} onClose={() => setSeriesDialog(null)} />
      )}
      {seriesDialog === 'end' && liveSeries && (
        <EndSeriesDialog job={job} series={liveSeries} onClose={() => setSeriesDialog(null)} />
      )}
    </SectionCard>
  );
}

/** Whether the job's series row is known (managers only; 'none' = not a repeat / not read). */
type SeriesStatus = 'none' | 'loading' | 'error' | 'ready';

interface SeriesBannerProps {
  job: JobDetail;
  /** null for technicians (they never read series rows) or while loading. */
  series: SeriesRow | null;
  loading: boolean;
  /** The series row failed to load (managers). */
  error: unknown;
  onRetry: () => void;
  retrying: boolean;
  onEditRepeat: (() => void) | undefined;
  onEnd: (() => void) | undefined;
}

/** "Repeats every 2 weeks on Tue · Visit 3 of 12" with the series actions. */
function SeriesBanner({
  job,
  series,
  loading,
  error,
  onRetry,
  retrying,
  onEditRepeat,
  onEnd,
}: SeriesBannerProps) {
  const visit = visitLabel(job.series_seq, series?.max_occurrences ?? null);
  return (
    <div className="bg-surface-2 rounded-control mb-3 flex flex-wrap items-center justify-between gap-2 px-3 py-2">
      <p className="text-ink flex min-w-0 items-start gap-2 text-sm">
        <Repeat className="text-primary-ink mt-0.5 size-4 shrink-0" aria-hidden="true" />
        <span className="min-w-0">
          <span className="font-medium">
            {series
              ? `Repeats ${describeSeries(series).replace(/^Every/, 'every')}`
              : loading
                ? 'Repeating job'
                : 'Part of a repeating job'}
          </span>
          {visit && <span className="text-muted"> · {visit}</span>}
          {series && !series.active && (
            <span className="text-muted block text-xs">This repeat has ended.</span>
          )}
          {job.series_detached && (
            <span className="text-muted block text-xs">
              This visit was changed on its own; repeat edits leave it as it is.
            </span>
          )}
          {error !== null && (
            <span className="text-danger-ink block text-xs" role="alert">
              Couldn’t load the repeat details, so the repeat can’t be changed right now.
            </span>
          )}
        </span>
      </p>
      {error !== null && (
        <Button size="sm" variant="secondary" loading={retrying} onClick={onRetry}>
          Try again
        </Button>
      )}
      {(onEditRepeat || onEnd) && (
        <span className="flex gap-1">
          {onEditRepeat && (
            <Button size="sm" variant="ghost" onClick={onEditRepeat}>
              Edit repeat
            </Button>
          )}
          {onEnd && (
            <Button size="sm" variant="ghost" onClick={onEnd}>
              End repeat
            </Button>
          )}
        </span>
      )}
    </div>
  );
}

interface ScheduleDialogProps {
  job: JobDetail;
  /** The job's live series: the change may apply to this and following visits. */
  series: SeriesRow | null;
  /** Saving waits until a repeating visit's series is known ('loading' / 'error'). */
  seriesStatus: SeriesStatus;
  seriesError: unknown;
  onRetrySeries: () => void;
  retryingSeries: boolean;
  onClose: () => void;
  resources: { id: string; name: string }[];
}

type Scope = 'this' | 'following';

function ScheduleDialog({
  job,
  series,
  seriesStatus,
  seriesError,
  onRetrySeries,
  retryingSeries,
  onClose,
  resources,
}: ScheduleDialogProps) {
  const { timezone } = useShop();
  const toast = useToast();
  const update = useUpdateJob(job.id);
  const updateSeries = useUpdateSeries();
  const follow = useFollowSeriesEdit();
  const [scope, setScope] = useState<Scope>('this');
  const saving = update.isPending || updateSeries.isPending;
  const seriesUnknown = seriesStatus === 'loading' || seriesStatus === 'error';
  const start = job.scheduled_start ? utcToShopLocal(job.scheduled_start, timezone) : null;
  const end = job.scheduled_end ? utcToShopLocal(job.scheduled_end, timezone) : null;
  const [form, setForm] = useState({
    startDate: start?.date ?? '',
    startTime: start?.time ?? '',
    endDate: end?.date ?? '',
    endTime: end?.time ?? '',
    location: job.location_type,
    line1: job.service_address_line1 ?? '',
    line2: job.service_address_line2 ?? '',
    city: job.service_city ?? '',
    region: job.service_region ?? '',
    postal: job.service_postal_code ?? '',
    resourceId: job.resource_id ?? '',
  });
  const [error, setError] = useState<string | null>(null);
  const set = (patch: Partial<typeof form>) => setForm((f) => ({ ...f, ...patch }));
  const canUnschedule = job.status === 'requested' || job.status === 'cancelled';

  const save = async () => {
    setError(null);
    if (seriesUnknown) return;
    const empty = !form.startDate && !form.startTime && !form.endDate && !form.endTime;
    let times: { start: string | null; end: string | null };
    if (empty) {
      if (!canUnschedule) {
        setError('A scheduled job needs a start and end time.');
        return;
      }
      times = { start: null, end: null };
    } else {
      const result = scheduleToUtc(
        { date: form.startDate, time: form.startTime },
        { date: form.endDate, time: form.endTime },
        timezone,
      );
      if ('error' in result) {
        setError(result.error);
        return;
      }
      times = result;
    }
    const mobile = form.location === 'mobile';
    const text = (v: string) => (mobile && v.trim() ? v.trim() : null);
    const patch: JobPatch = {
      scheduled_start: times.start,
      scheduled_end: times.end,
      location_type: form.location,
      service_address_line1: text(form.line1),
      service_address_line2: text(form.line2),
      service_city: text(form.city),
      service_region: text(form.region),
      service_postal_code: text(form.postal),
      resource_id: form.resourceId || null,
    };
    if (scope === 'following' && series) {
      await saveFollowing(series, patch, times);
      return;
    }
    try {
      await update.mutateAsync(patch);
      toast.success('Schedule saved');
      onClose();
    } catch (err) {
      toast.error(err);
    }
  };

  /**
   * "This and following": the series defaults change from this visit on
   * (update_job_series). The day of the week / month is the repeat rule's,
   * so a new date applies to this visit only.
   */
  const saveFollowing = async (
    s: SeriesRow,
    patch: JobPatch,
    times: { start: string | null; end: string | null },
  ) => {
    const visitDate = jobLocalDate(job, timezone);
    if (!times.start || !times.end) {
      setError('Repeating visits need a start and end time.');
      return;
    }
    if (form.startDate !== visitDate) {
      setError(
        'A new date applies to this visit only. To move the following visits to other days, use “Edit repeat”.',
      );
      return;
    }
    const minutes = spanMinutes(times.start, times.end);
    if (minutes === null || minutes < SERIES_LIMITS.durationMin) {
      setError('Repeating visits last at least 15 minutes.');
      return;
    }
    const seriesPatch: Record<string, unknown> = {};
    if (form.startTime !== s.local_start.slice(0, 5)) seriesPatch.local_start = form.startTime;
    if (minutes !== s.duration_minutes) seriesPatch.duration_minutes = minutes;
    const keys = [
      'location_type',
      'service_address_line1',
      'service_address_line2',
      'service_city',
      'service_region',
      'service_postal_code',
      'resource_id',
    ] as const;
    for (const key of keys) {
      if (patch[key] !== job[key]) seriesPatch[key] = patch[key];
    }
    if (Object.keys(seriesPatch).length === 0) {
      setError('Nothing changed. Edit the time, location or bay / van first.');
      return;
    }
    try {
      const result = await updateSeries.mutateAsync({
        seriesId: s.id,
        jobId: job.id,
        jobDate: visitDate,
        patch: seriesPatch,
      });
      // A visit the series had to keep (confirmed, paid, worked on) still
      // gets the change when it is the one being edited.
      if (result.stillThere) await update.mutateAsync(patch);
      toast.success('Following visits updated', describeSeriesEdit(result));
      onClose();
      follow(result);
    } catch (err) {
      toast.error(err);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      title="Edit schedule & location"
      description={`Times are in the shop’s time zone (${timezone}).`}
      size="lg"
      dismissible={!saving}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button loading={saving} disabled={seriesUnknown} onClick={() => void save()}>
            Save
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        {seriesStatus === 'loading' && <LoadingState label="Loading the repeat…" />}
        {seriesStatus === 'error' && (
          <ErrorState
            compact
            title="Couldn’t load the repeat details"
            error={seriesError}
            onRetry={onRetrySeries}
            retrying={retryingSeries}
          />
        )}
        {seriesStatus === 'error' && (
          <p className="text-muted text-sm">
            Saving now could only change this visit, which would take it out of the repeat for good.
            Try again to choose between this visit and the following ones.
          </p>
        )}
        {series && (
          <RadioGroup<Scope>
            label="Apply to"
            orientation="horizontal"
            value={scope}
            onChange={setScope}
            options={[
              { value: 'this', label: 'This visit only' },
              { value: 'following', label: 'This and following visits' },
            ]}
          />
        )}
        {series && scope === 'this' && !job.series_detached && (
          <p className="text-muted -mt-2 text-xs">
            A new time, place or bay / van takes this visit out of the repeat: later repeat edits
            leave it as it is.
          </p>
        )}
        <div className="grid grid-cols-2 gap-3">
          <FormField label="Start date">
            <DateInput
              value={form.startDate}
              onChange={(e) => set({ startDate: e.target.value })}
            />
          </FormField>
          <FormField label="Start time">
            <TimeInput
              value={form.startTime}
              onChange={(e) => set({ startTime: e.target.value })}
            />
          </FormField>
          <FormField label="End date">
            <DateInput value={form.endDate} onChange={(e) => set({ endDate: e.target.value })} />
          </FormField>
          <FormField label="End time">
            <TimeInput value={form.endTime} onChange={(e) => set({ endTime: e.target.value })} />
          </FormField>
        </div>
        {canUnschedule && (
          <p className="text-muted text-xs">Clear all four fields to leave the job unscheduled.</p>
        )}
        <RadioGroup<LocationType>
          label="Location"
          orientation="horizontal"
          value={form.location}
          onChange={(location) => set({ location })}
          options={[
            { value: 'shop', label: 'At the shop' },
            { value: 'mobile', label: 'Mobile (customer’s address)' },
          ]}
        />
        {form.location === 'mobile' && (
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <FormField label="Street address" className="sm:col-span-2">
              <Input
                value={form.line1}
                maxLength={200}
                autoComplete="address-line1"
                onChange={(e) => set({ line1: e.target.value })}
              />
            </FormField>
            <FormField label="Apt, suite, etc." className="sm:col-span-2">
              <Input
                value={form.line2}
                maxLength={200}
                onChange={(e) => set({ line2: e.target.value })}
              />
            </FormField>
            <FormField label="City">
              <Input
                value={form.city}
                maxLength={100}
                onChange={(e) => set({ city: e.target.value })}
              />
            </FormField>
            <div className="grid grid-cols-2 gap-3">
              <FormField label="State">
                <Input
                  value={form.region}
                  maxLength={100}
                  onChange={(e) => set({ region: e.target.value })}
                />
              </FormField>
              <FormField label="ZIP">
                <Input
                  value={form.postal}
                  maxLength={20}
                  onChange={(e) => set({ postal: e.target.value })}
                />
              </FormField>
            </div>
          </div>
        )}
        <FormField label="Bay / van">
          <Select
            value={form.resourceId}
            onChange={(e) => set({ resourceId: e.target.value })}
            options={[
              { value: '', label: 'None' },
              ...resources.map((r) => ({ value: r.id, label: r.name })),
            ]}
          />
        </FormField>
        {error && (
          <p role="alert" className="text-danger-ink text-sm">
            {error}
          </p>
        )}
      </div>
    </Dialog>
  );
}
