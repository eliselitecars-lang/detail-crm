import { useState } from 'react';
import { Button, DateInput, Dialog, FormField, useToast } from '@/components/ui';
import { formatLocalDate, isLocalDate } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import type { JobDetail } from '../../api';
import {
  currentMonthRule,
  draftFromSeries,
  jobLocalDate,
  repeatRuleFields,
  type RepeatDraft,
  type SeriesRow,
} from '../../series';
import {
  describeSeriesEdit,
  useEndSeries,
  useFollowSeriesEdit,
  useUpdateSeries,
} from '../../seriesApi';
import { RepeatFields, SeriesPreview } from '../RepeatFields';

interface SeriesDialogProps {
  job: JobDetail;
  series: SeriesRow;
  onClose: () => void;
}

/**
 * Changes the repeat rule from this visit on ("this and following"). The
 * server re-anchors the rule at this visit and replaces the upcoming visits
 * that nobody confirmed, paid or worked on; the others keep their date.
 */
export function EditRepeatDialog({ job, series, onClose }: SeriesDialogProps) {
  const { timezone } = useShop();
  const toast = useToast();
  const update = useUpdateSeries();
  const follow = useFollowSeriesEdit();
  const anchor = jobLocalDate(job, timezone);
  const [draft, setDraft] = useState<RepeatDraft>(() => draftFromSeries(series));
  const [error, setError] = useState<string | null>(null);
  // A monthly rule is sent back unchanged unless another option is picked:
  // rebuilt from this visit's date it could differ (a clamped "day 31" visit,
  // a visit moved on its own) and the server would re-anchor the series.
  const current = currentMonthRule(series);
  const rule = repeatRuleFields(draft, anchor, current);
  const previewPayload =
    'error' in rule
      ? null
      : {
          ...rule,
          start_date: anchor,
          local_start: series.local_start.slice(0, 5),
          duration_minutes: series.duration_minutes,
        };

  const save = async () => {
    setError(null);
    if ('error' in rule) {
      setError(rule.error);
      return;
    }
    try {
      const result = await update.mutateAsync({
        seriesId: series.id,
        jobId: job.id,
        jobDate: anchor,
        patch: { ...rule },
      });
      toast.success('Repeat updated', describeSeriesEdit(result));
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
      title="Edit repeat"
      description={`Applies to this visit (${formatLocalDate(anchor, 'EEE, MMM d')}) and the ones after it.`}
      size="md"
      dismissible={!update.isPending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={update.isPending}>
            Cancel
          </Button>
          <Button loading={update.isPending} onClick={() => void save()}>
            Save repeat
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        <RepeatFields
          draft={draft}
          onChange={setDraft}
          anchorDate={anchor}
          currentMonthRule={current}
          disabled={update.isPending}
        />
        <SeriesPreview payload={previewPayload} timezone={timezone} />
        <p className="text-muted text-xs">
          Upcoming visits that are confirmed, paid, invoiced or already worked on keep their date.
        </p>
        {error && (
          <p role="alert" className="text-danger-ink text-sm">
            {error}
          </p>
        )}
      </div>
    </Dialog>
  );
}

/** Stops the series after a date (end_job_series). */
export function EndSeriesDialog({ job, series, onClose }: SeriesDialogProps) {
  const { timezone } = useShop();
  const toast = useToast();
  const end = useEndSeries();
  const follow = useFollowSeriesEdit();
  const visitDate = jobLocalDate(job, timezone);
  const [afterDate, setAfterDate] = useState(visitDate);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    setError(null);
    if (!isLocalDate(afterDate)) {
      setError('Choose the date of the last visit.');
      return;
    }
    try {
      const result = await end.mutateAsync({
        seriesId: series.id,
        jobId: job.id,
        jobDate: visitDate,
        afterDate,
      });
      toast.success(
        'Repeat ended',
        result.deleted === 0 && result.kept === 0
          ? 'No visits after that date.'
          : describeSeriesEdit(result),
      );
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
      title="End this repeating job?"
      description="No new visits are created after the last visit date."
      size="sm"
      dismissible={!end.isPending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={end.isPending}>
            Keep repeating
          </Button>
          <Button variant="danger" loading={end.isPending} onClick={() => void save()}>
            End repeat
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        <FormField
          label="Last visit date"
          help="Visits after it are removed unless they are confirmed, paid, invoiced or already worked on."
          error={error ?? undefined}
        >
          <DateInput value={afterDate} onChange={(e) => setAfterDate(e.target.value)} />
        </FormField>
      </div>
    </Dialog>
  );
}
