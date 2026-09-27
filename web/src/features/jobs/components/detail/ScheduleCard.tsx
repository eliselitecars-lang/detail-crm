import { Pencil } from 'lucide-react';
import { useState } from 'react';
import {
  Button,
  DateInput,
  Dialog,
  FormField,
  Input,
  KeyValueList,
  RadioGroup,
  SectionCard,
  Select,
  TimeInput,
  useToast,
} from '@/components/ui';
import { formatInTz, formatTimeRange, utcToShopLocal } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useResources, useUpdateJob, type JobDetail } from '../../api';
import { formatDuration, scheduleToUtc, type LocationType } from '../../model';
import { LocationLine } from './PeopleCards';

export function ScheduleCard({ job }: { job: JobDetail }) {
  const { timezone } = useShop();
  const canManage = useCan('jobs.manage');
  const resources = useResources();
  const [editing, setEditing] = useState(false);
  const resource = resources.data?.find((r) => r.id === job.resource_id);

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
          onClose={() => setEditing(false)}
          resources={(resources.data ?? []).filter(
            (r) => (r.active && !r.archived_at) || r.id === job.resource_id,
          )}
        />
      )}
    </SectionCard>
  );
}

interface ScheduleDialogProps {
  job: JobDetail;
  onClose: () => void;
  resources: { id: string; name: string }[];
}

function ScheduleDialog({ job, onClose, resources }: ScheduleDialogProps) {
  const { timezone } = useShop();
  const toast = useToast();
  const update = useUpdateJob(job.id);
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
    try {
      await update.mutateAsync({
        scheduled_start: times.start,
        scheduled_end: times.end,
        location_type: form.location,
        service_address_line1: text(form.line1),
        service_address_line2: text(form.line2),
        service_city: text(form.city),
        service_region: text(form.region),
        service_postal_code: text(form.postal),
        resource_id: form.resourceId || null,
      });
      toast.success('Schedule saved');
      onClose();
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
      dismissible={!update.isPending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={update.isPending}>
            Cancel
          </Button>
          <Button loading={update.isPending} onClick={() => void save()}>
            Save
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <div className="grid grid-cols-2 gap-3">
          <FormField label="Start date">
            <DateInput value={form.startDate} onChange={(e) => set({ startDate: e.target.value })} />
          </FormField>
          <FormField label="Start time">
            <TimeInput value={form.startTime} onChange={(e) => set({ startTime: e.target.value })} />
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
              <Input value={form.line2} maxLength={200} onChange={(e) => set({ line2: e.target.value })} />
            </FormField>
            <FormField label="City">
              <Input value={form.city} maxLength={100} onChange={(e) => set({ city: e.target.value })} />
            </FormField>
            <div className="grid grid-cols-2 gap-3">
              <FormField label="State">
                <Input value={form.region} maxLength={100} onChange={(e) => set({ region: e.target.value })} />
              </FormField>
              <FormField label="ZIP">
                <Input value={form.postal} maxLength={20} onChange={(e) => set({ postal: e.target.value })} />
              </FormField>
            </div>
          </div>
        )}
        <FormField label="Bay / van">
          <Select
            value={form.resourceId}
            onChange={(e) => set({ resourceId: e.target.value })}
            options={[{ value: '', label: 'None' }, ...resources.map((r) => ({ value: r.id, label: r.name }))]}
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
