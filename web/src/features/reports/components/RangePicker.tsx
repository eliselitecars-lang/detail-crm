import { DateInput, FormField, Select } from '@/components/ui';
import { formatLocalDate } from '@/lib/dates';
import {
  BUCKET_LABELS,
  bucketAllowed,
  BUCKETS,
  isBucket,
  isPreset,
  PRESET_LABELS,
  PRESETS,
  type Bucket,
  type DateRange,
  type Preset,
} from '../ranges';

export interface RangePickerProps {
  preset: Preset;
  range: DateRange;
  bucket: Bucket;
  error: string | null;
  showBucket: boolean;
  onPresetChange: (preset: Preset) => void;
  /** Only the edited end is passed, so quick successive edits compose. */
  onCustomChange: (patch: Partial<DateRange>) => void;
  onBucketChange: (bucket: Bucket) => void;
}

/** Date-range presets (shop time zone) + custom dates + chart bucket. */
export function RangePicker({
  preset,
  range,
  bucket,
  error,
  showBucket,
  onPresetChange,
  onCustomChange,
  onBucketChange,
}: RangePickerProps) {
  const label =
    error === null && range.from && range.to
      ? range.from === range.to
        ? formatLocalDate(range.from, 'EEE, MMM d, yyyy')
        : `${formatLocalDate(range.from)} – ${formatLocalDate(range.to)}`
      : null;
  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-end">
        <FormField label="Date range" className="sm:w-44">
          <Select
            value={preset}
            onChange={(e) => {
              if (isPreset(e.target.value)) onPresetChange(e.target.value);
            }}
            options={PRESETS.map((p) => ({ value: p, label: PRESET_LABELS[p] }))}
          />
        </FormField>
        {preset === 'custom' && (
          <div className="grid grid-cols-2 gap-3 sm:flex">
            <FormField label="From">
              <DateInput
                value={range.from}
                max={range.to || undefined}
                onChange={(e) => onCustomChange({ from: e.target.value })}
              />
            </FormField>
            <FormField label="To">
              <DateInput
                value={range.to}
                min={range.from || undefined}
                onChange={(e) => onCustomChange({ to: e.target.value })}
              />
            </FormField>
          </div>
        )}
        {showBucket && (
          <FormField label="Group by" className="sm:w-36">
            <Select
              value={bucket}
              onChange={(e) => {
                if (isBucket(e.target.value)) onBucketChange(e.target.value);
              }}
              options={BUCKETS.map((b) => {
                const disabled = error === null && !bucketAllowed(range, b);
                return {
                  value: b,
                  label: disabled ? `${BUCKET_LABELS[b]} (range too long)` : BUCKET_LABELS[b],
                  disabled,
                };
              })}
            />
          </FormField>
        )}
      </div>
      {error ? (
        <p role="alert" className="text-danger-ink text-sm font-medium">
          {error}
        </p>
      ) : (
        label && <p className="text-muted text-sm">{label} · shop time zone</p>
      )}
    </div>
  );
}
