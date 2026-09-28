import { CalendarCheck, ChevronLeft, ChevronRight, CreditCard, RefreshCw } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router';
import {
  Button,
  buttonClasses,
  EmptyState,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  RadioGroup,
  SectionCard,
} from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatDateTime, formatTime, shopToday } from '@/lib/dates';
import { errorMessage, toAppError } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import {
  useBookingProfile,
  useQuoteDepositCheckout,
  useQuoteSlots,
  useScheduleQuote,
  type QuoteDocument,
  type QuoteSlot,
  type ScheduleLocationType,
} from '../api';
import {
  dayLabels,
  dayWindow,
  DEFAULT_MAX_DAYS_AHEAD,
  groupSlotsByDay,
  SCHEDULE_WINDOW_DAYS,
  shiftWindow,
} from '../schedule';
import { timeZoneName } from '../shared/format';
import { Banner } from '../shared/PublicPage';

interface Address {
  line1: string;
  line2: string;
  city: string;
  region: string;
  postal: string;
}

const EMPTY_ADDRESS: Address = { line1: '', line2: '', city: '', region: '', postal: '' };

function addressProblem(address: Address): string | null {
  if (!address.line1.trim()) return 'Enter the street address.';
  if (!address.city.trim()) return 'Enter the city.';
  if (!address.postal.trim()) return 'Enter the postal code.';
  if (address.line1.length > 200 || address.line2.length > 200) return 'The address is too long.';
  if (address.city.length > 100 || address.region.length > 100) return 'The city is too long.';
  if (address.postal.length > 20) return 'The postal code is too long.';
  return null;
}

/**
 * "Pick a time" for an approved quote (public_quote_slots → public_schedule_quote).
 * Times come from the shop's online booking engine and are shown in the
 * shop's time zone; the chosen one is re-checked when booking.
 */
export function QuoteSchedulePanel({ token, doc }: { token: string; doc: QuoteDocument }) {
  const { shop } = doc;
  const tz = shop.timezone;
  const profile = useBookingProfile(shop.slug, true);
  const today = shopToday(tz);
  const [windowStart, setWindowStart] = useState(today);
  const [day, setDay] = useState<string | null>(null);
  const [slot, setSlot] = useState<QuoteSlot | null>(null);
  const [location, setLocation] = useState<ScheduleLocationType | null>(null);
  const [address, setAddress] = useState<Address>(EMPTY_ADDRESS);
  const [formError, setFormError] = useState<string | null>(null);
  const schedule = useScheduleQuote(token);

  const businessType = profile.data?.business_type ?? null;
  // What the booking engine is asked for: the customer's pick, else what the shop offers.
  const effectiveLocation: ScheduleLocationType | null =
    businessType === 'fixed' ? 'shop' : businessType === 'mobile' ? 'mobile' : location;
  const maxDaysAhead = profile.data?.booking.max_days_ahead ?? DEFAULT_MAX_DAYS_AHEAD;
  const days = dayWindow(windowStart);
  const lastDay = days[days.length - 1] ?? windowStart;
  const ready = businessType !== null && (businessType !== 'both' || location !== null);
  const slots = useQuoteSlots(
    token,
    ready ? { from: windowStart, to: lastDay } : null,
    effectiveLocation,
  );
  const byDay = groupSlotsByDay(slots.data ?? [], tz);
  const daySlots = day ? (byDay.get(day) ?? []) : [];
  const canGoBack = windowStart > today;
  const canGoForward = shiftWindow(windowStart, 1, today, maxDaysAhead) !== windowStart;

  const book = () => {
    setFormError(null);
    if (!slot) {
      setFormError('Choose a time first.');
      return;
    }
    let payload: Parameters<typeof schedule.mutate>[0]['location'] = null;
    if (effectiveLocation === 'mobile') {
      const problem = addressProblem(address);
      if (problem) {
        setFormError(problem);
        return;
      }
      payload = {
        type: 'mobile',
        address_line1: address.line1.trim(),
        city: address.city.trim(),
        postal_code: address.postal.trim(),
        ...(address.line2.trim() ? { address_line2: address.line2.trim() } : {}),
        ...(address.region.trim() ? { region: address.region.trim() } : {}),
      };
    } else if (effectiveLocation === 'shop') {
      payload = { type: 'shop' };
    }
    schedule.mutate(
      { startsAt: slot.starts_at, location: payload },
      {
        onError: (error) => {
          // Someone else took the time: show fresh times.
          if (toAppError(error).code === '23P01') {
            setSlot(null);
            void slots.refetch();
          }
        },
      },
    );
  };

  return (
    <SectionCard
      title="Pick a time"
      description={`Times are shown in ${timeZoneName(tz)}.`}
      className="print:hidden"
    >
      <div className="flex flex-col gap-4">
        {profile.isPending ? (
          <LoadingState variant="rows" rows={2} label="Loading scheduling…" />
        ) : profile.isError ? (
          <ErrorState compact error={profile.error} onRetry={() => void profile.refetch()} />
        ) : (
          <>
            {profile.data.booking.booking_message && (
              <p className="text-muted text-sm whitespace-pre-line">
                {profile.data.booking.booking_message}
              </p>
            )}
            {businessType === 'both' && (
              <RadioGroup<ScheduleLocationType>
                label="Where should the work be done?"
                value={location}
                onChange={(value) => {
                  setLocation(value);
                  setDay(null);
                  setSlot(null);
                }}
                variant="cards"
                orientation="horizontal"
                options={[
                  { value: 'shop', label: 'At the shop', description: shop.name },
                  { value: 'mobile', label: 'At my address', description: 'We come to you' },
                ]}
              />
            )}
            {ready && (
              <DayStrip
                days={days}
                byDay={byDay}
                selected={day}
                loading={slots.isPending || slots.isFetching}
                onSelect={(next) => {
                  setDay(next);
                  setSlot(null);
                }}
                onPrevious={
                  canGoBack
                    ? () => {
                        setWindowStart(shiftWindow(windowStart, -1, today, maxDaysAhead));
                        setDay(null);
                        setSlot(null);
                      }
                    : null
                }
                onNext={
                  canGoForward
                    ? () => {
                        setWindowStart(shiftWindow(windowStart, 1, today, maxDaysAhead));
                        setDay(null);
                        setSlot(null);
                      }
                    : null
                }
              />
            )}
            {ready && slots.isError && (
              <ErrorState
                compact
                title="Couldn’t load times"
                error={slots.error}
                onRetry={() => void slots.refetch()}
              />
            )}
            {ready && slots.isSuccess && byDay.size === 0 && (
              <EmptyState
                compact
                title="No open times these days"
                description={
                  canGoForward
                    ? 'Try the next days, or contact the shop.'
                    : `Contact ${shop.name} to schedule.`
                }
              />
            )}
            {day && daySlots.length > 0 && (
              <div
                role="radiogroup"
                aria-label="Start times"
                className="grid grid-cols-3 gap-2 sm:grid-cols-4"
              >
                {daySlots.map((option) => {
                  const active = slot?.starts_at === option.starts_at;
                  return (
                    <button
                      key={option.starts_at}
                      type="button"
                      role="radio"
                      aria-checked={active}
                      onClick={() => setSlot(option)}
                      className={cn(
                        'rounded-control border px-2 py-2 text-sm font-medium tabular-nums',
                        active
                          ? 'border-brand bg-brand text-brand-fg'
                          : 'border-line bg-surface text-ink hover:border-line-strong',
                      )}
                    >
                      {formatTime(option.starts_at, tz)}
                    </button>
                  );
                })}
              </div>
            )}
            {effectiveLocation === 'mobile' && slot && (
              <fieldset className="flex flex-col gap-3">
                <legend className="text-ink mb-1 text-sm font-medium">Service address</legend>
                <FormField label="Street address" required>
                  <Input
                    value={address.line1}
                    autoComplete="address-line1"
                    maxLength={200}
                    onChange={(e) => setAddress({ ...address, line1: e.target.value })}
                  />
                </FormField>
                <FormField label="Apartment, suite (optional)">
                  <Input
                    value={address.line2}
                    autoComplete="address-line2"
                    maxLength={200}
                    onChange={(e) => setAddress({ ...address, line2: e.target.value })}
                  />
                </FormField>
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
                  <FormField label="City" required>
                    <Input
                      value={address.city}
                      autoComplete="address-level2"
                      maxLength={100}
                      onChange={(e) => setAddress({ ...address, city: e.target.value })}
                    />
                  </FormField>
                  <FormField label="State / region">
                    <Input
                      value={address.region}
                      autoComplete="address-level1"
                      maxLength={100}
                      onChange={(e) => setAddress({ ...address, region: e.target.value })}
                    />
                  </FormField>
                  <FormField label="Postal code" required>
                    <Input
                      value={address.postal}
                      autoComplete="postal-code"
                      maxLength={20}
                      onChange={(e) => setAddress({ ...address, postal: e.target.value })}
                    />
                  </FormField>
                </div>
              </fieldset>
            )}
            {(formError || schedule.isError) && (
              <Banner tone="danger" title="Couldn’t book that time">
                {formError ?? errorMessage(schedule.error)}
              </Banner>
            )}
            {profile.data.booking.cancellation_policy && (
              <p className="text-muted text-xs whitespace-pre-line">
                {profile.data.booking.cancellation_policy}
              </p>
            )}
            <div className="flex justify-end">
              <Button
                size="lg"
                loading={schedule.isPending}
                disabled={!slot}
                leadingIcon={<CalendarCheck className="size-4" aria-hidden="true" />}
                onClick={book}
              >
                {slot ? `Book ${formatDateTime(slot.starts_at, tz)}` : 'Book this time'}
              </Button>
            </div>
          </>
        )}
      </div>
    </SectionCard>
  );
}

function DayStrip({
  days,
  byDay,
  selected,
  loading,
  onSelect,
  onPrevious,
  onNext,
}: {
  days: readonly string[];
  byDay: Map<string, QuoteSlot[]>;
  selected: string | null;
  loading: boolean;
  onSelect: (day: string) => void;
  onPrevious: (() => void) | null;
  onNext: (() => void) | null;
}) {
  return (
    <div className="flex items-stretch gap-2">
      <Button
        variant="ghost"
        size="sm"
        aria-label="Earlier days"
        disabled={!onPrevious}
        onClick={() => onPrevious?.()}
      >
        <ChevronLeft className="size-4" aria-hidden="true" />
      </Button>
      <div
        role="radiogroup"
        aria-label="Days"
        aria-busy={loading}
        className="grid flex-1 gap-1.5"
        style={{ gridTemplateColumns: `repeat(${SCHEDULE_WINDOW_DAYS}, minmax(0, 1fr))` }}
      >
        {days.map((date) => {
          const count = byDay.get(date)?.length ?? 0;
          const active = selected === date;
          const labels = dayLabels(date);
          return (
            <button
              key={date}
              type="button"
              role="radio"
              aria-checked={active}
              aria-label={`${labels.weekday} ${labels.day}${count === 0 ? ', no times' : `, ${count} times`}`}
              disabled={loading || count === 0}
              onClick={() => onSelect(date)}
              className={cn(
                'rounded-control flex flex-col items-center border px-1 py-2 text-xs disabled:opacity-40',
                active
                  ? 'border-brand bg-brand text-brand-fg'
                  : 'border-line bg-surface text-ink hover:border-line-strong',
              )}
            >
              <span className="font-medium">{labels.weekday}</span>
              <span className="tabular-nums">{labels.day}</span>
            </button>
          );
        })}
      </div>
      <Button
        variant="ghost"
        size="sm"
        aria-label="Later days"
        disabled={!onNext}
        onClick={() => onNext?.()}
      >
        <ChevronRight className="size-4" aria-hidden="true" />
      </Button>
    </div>
  );
}

/**
 * The quote the customer scheduled on this page: the booking link and, when
 * one is due, the deposit (payments quote_deposit_checkout). Amounts are the
 * server's (deposit_due_cents counts only money received, so it is never
 * asked for again while a payment is on its way).
 */
function CheckAgainButton({
  refreshing,
  onRefresh,
}: {
  refreshing: boolean;
  onRefresh: () => void;
}) {
  return (
    <Button
      size="sm"
      variant="secondary"
      loading={refreshing}
      leadingIcon={<RefreshCw className="size-4" aria-hidden="true" />}
      onClick={onRefresh}
    >
      Check again
    </Button>
  );
}

export function QuoteScheduledPanel({
  token,
  doc,
  paidReturn,
  pollingDone,
  canceledReturn,
  refreshing,
  onRefresh,
}: {
  token: string;
  doc: QuoteDocument;
  paidReturn: boolean;
  /** Back from Stripe: the deposit settled, or the page stopped re-checking. */
  pollingDone: boolean;
  canceledReturn: boolean;
  refreshing: boolean;
  onRefresh: () => void;
}) {
  const { shop, self_schedule: schedule } = doc;
  const currency = shop.currency;
  const checkout = useQuoteDepositCheckout(token);
  const due = schedule.deposit_due_cents ?? 0;
  const jobToken = schedule.job_token;

  return (
    <SectionCard title="You’re booked" className="print:hidden">
      <div className="flex flex-col gap-4">
        <p className="text-ink text-sm">
          Your appointment request is with {shop.name}. You’ll get a confirmation message with the
          details.
        </p>
        {paidReturn && !pollingDone && (schedule.payment_pending || due > 0) && (
          <Banner
            tone="info"
            title="Confirming your deposit…"
            action={<CheckAgainButton refreshing={refreshing} onRefresh={onRefresh} />}
          >
            This usually takes a few seconds. You don’t need to pay again.
          </Banner>
        )}
        {paidReturn && pollingDone && !schedule.payment_pending && due > 0 && (
          <Banner
            tone="warning"
            title="We’re still confirming your deposit"
            action={<CheckAgainButton refreshing={refreshing} onRefresh={onRefresh} />}
          >
            If you completed checkout, don’t pay again — this page updates once the payment clears.{' '}
            <Link to={`/q/${token}`} className="underline">
              Pay the deposit
            </Link>
          </Banner>
        )}
        {paidReturn && !schedule.payment_pending && due <= 0 && (
          <Banner tone="success" title="Deposit received — thank you!" />
        )}
        {canceledReturn && due > 0 && !schedule.payment_pending && (
          <Banner tone="info" title="Payment cancelled">
            You weren’t charged. You can pay the deposit whenever you’re ready.
          </Banner>
        )}
        {(!paidReturn || pollingDone) && schedule.payment_pending && (
          <Banner tone="info" title="Your deposit payment is processing">
            Bank payments can take a few days to clear. There’s nothing more to do.
          </Banner>
        )}
        {due > 0 && !schedule.payment_pending && !paidReturn && (
          <div className="border-line rounded-card flex flex-col gap-3 border p-4">
            <p className="text-ink text-sm">
              A deposit of{' '}
              <span className="font-semibold tabular-nums">{formatCents(due, { currency })}</span>{' '}
              holds your time.
            </p>
            <p className="text-muted text-xs">
              Paying saves your card securely with Stripe so {shop.name} can charge the rest of this
              job’s balance to it. Card numbers are never stored by the shop.
            </p>
            {checkout.isError && (
              <Banner tone="danger" title="Couldn’t start the payment">
                {errorMessage(checkout.error)}
              </Banner>
            )}
            <Button
              variant="money"
              size="lg"
              fullWidth
              loading={checkout.isPending || checkout.isSuccess}
              leadingIcon={<CreditCard className="size-4" aria-hidden="true" />}
              onClick={() => checkout.mutate()}
            >
              {`Pay ${formatCents(due, { currency })} deposit`}
            </Button>
          </div>
        )}
        {jobToken && (
          <Link
            to={`/booking/${jobToken}`}
            className={buttonClasses({ variant: 'secondary', className: 'self-start' })}
          >
            Manage your appointment
          </Link>
        )}
      </div>
    </SectionCard>
  );
}
