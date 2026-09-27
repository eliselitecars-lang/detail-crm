import { useState } from 'react';
import { useNavigate } from 'react-router';
import {
  Button,
  DateInput,
  Dialog,
  FormField,
  RadioGroup,
  TimeInput,
  useToast,
} from '@/components/ui';
import { addLocalDays, isLocalDate, isLocalTime, shopLocalToUtcIso, shopToday } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useConvertQuote } from '../api';
import { defaultEnd } from './schedule';

export interface ConvertQuoteDialogProps {
  open: boolean;
  onClose: () => void;
  quoteId: string;
  quoteNumber: number;
  /** Σ duration of the counted lines (minutes), for the default end time. */
  durationMinutes: number;
}

const DEFAULT_START = '09:00';

export function ConvertQuoteDialog(props: ConvertQuoteDialogProps) {
  return (
    <Dialog
      open={props.open}
      onClose={props.onClose}
      title={`Convert quote #${props.quoteNumber} to a job`}
      description="The job gets the quote’s line items (including the options the customer chose), discount and notes."
    >
      {props.open && <ConvertForm {...props} />}
    </Dialog>
  );
}

function ConvertForm({ onClose, quoteId, durationMinutes }: ConvertQuoteDialogProps) {
  const { timezone } = useShop();
  const toast = useToast();
  const navigate = useNavigate();
  const convert = useConvertQuote(quoteId);
  const today = shopToday(timezone);
  const initialEnd = defaultEnd(addLocalDays(today, 1), DEFAULT_START, durationMinutes);
  const [mode, setMode] = useState<'schedule' | 'later'>('schedule');
  const [startDate, setStartDate] = useState(addLocalDays(today, 1));
  const [startTime, setStartTime] = useState(DEFAULT_START);
  const [endDate, setEndDate] = useState(initialEnd.date);
  const [endTime, setEndTime] = useState(initialEnd.time);

  const validParts =
    isLocalDate(startDate) &&
    isLocalTime(startTime) &&
    isLocalDate(endDate) &&
    isLocalTime(endTime);
  const range = validParts
    ? {
        start: shopLocalToUtcIso(startDate, startTime, timezone),
        end: shopLocalToUtcIso(endDate, endTime, timezone),
      }
    : null;
  const error =
    mode === 'later'
      ? undefined
      : !range
        ? 'Enter a start and end date and time.'
        : range.end <= range.start
          ? 'The end must be after the start.'
          : undefined;

  const submit = async () => {
    if (error) return;
    try {
      const job = await convert.mutateAsync(
        mode === 'schedule' && range ? range : { start: null, end: null },
      );
      toast.success(`Job #${job.number} created`);
      onClose();
      await navigate(`/app/jobs/${job.id}`);
    } catch (err) {
      toast.error(err);
    }
  };

  return (
    <form
      noValidate
      className="flex flex-col gap-4"
      onSubmit={(event) => {
        event.preventDefault();
        void submit();
      }}
    >
      <RadioGroup<'schedule' | 'later'>
        label="Schedule"
        value={mode}
        onChange={setMode}
        options={[
          {
            value: 'schedule',
            label: 'Schedule it now',
            description: 'Times are in the shop’s time zone.',
          },
          {
            value: 'later',
            label: 'Schedule later',
            description: 'The job starts as “Requested”.',
          },
        ]}
      />
      {mode === 'schedule' && (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <FormField label="Start date" required>
            <DateInput
              value={startDate}
              onChange={(event) => {
                const next = event.target.value;
                setStartDate(next);
                if (isLocalDate(next) && isLocalTime(startTime)) {
                  const end = defaultEnd(next, startTime, durationMinutes);
                  setEndDate(end.date);
                  setEndTime(end.time);
                }
              }}
            />
          </FormField>
          <FormField label="Start time" required>
            <TimeInput
              value={startTime}
              onChange={(event) => {
                const next = event.target.value;
                setStartTime(next);
                if (isLocalDate(startDate) && isLocalTime(next)) {
                  const end = defaultEnd(startDate, next, durationMinutes);
                  setEndDate(end.date);
                  setEndTime(end.time);
                }
              }}
            />
          </FormField>
          <FormField label="End date" required>
            <DateInput value={endDate} onChange={(event) => setEndDate(event.target.value)} />
          </FormField>
          <FormField label="End time" required error={error}>
            <TimeInput value={endTime} onChange={(event) => setEndTime(event.target.value)} />
          </FormField>
        </div>
      )}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={convert.isPending}>
          Cancel
        </Button>
        <Button type="submit" loading={convert.isPending} disabled={Boolean(error)}>
          Create job
        </Button>
      </div>
    </form>
  );
}
