import { zodResolver } from '@hookform/resolvers/zod';
import { Controller, useForm, useWatch } from 'react-hook-form';
import {
  FormField,
  Input,
  MoneyInput,
  RadioGroup,
  SectionCard,
  Select,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { toAppError } from '@/lib/errors';
import { bpsToPercentInput } from '@/lib/money';
import { useBookingSettings, useUpdateBookingSettings, type BookingSettings } from '../api';
import { BookingLinkCard } from '../components/BookingLinkCard';
import { FormActions } from '../components/FormActions';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  bookingSchema,
  depositValueOf,
  DURATION_UNITS,
  joinMinutes,
  parsePostalCodes,
  splitMinutes,
  type BookingInput,
  type BookingValues,
} from '../schemas';
import { useSettingsAccess } from '../useSettingsAccess';

const UNIT_LABELS = { minutes: 'minutes', hours: 'hours', days: 'days' } as const;

export default function BookingSettingsPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const { shop } = useShop();
  const query = useBookingSettings();
  return (
    <SettingsSectionLayout section="booking" readOnly={readOnly}>
      <QueryView query={query} label="booking settings">
        {(settings) => (
          <>
            <BookingLinkCard slug={shop.slug} enabled={settings.enabled} />
            <BookingForm key={settings.shop_id} settings={settings} canEdit={canEdit} />
          </>
        )}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function toInput(s: BookingSettings): BookingInput {
  const lead = splitMinutes(s.lead_time_minutes);
  return {
    enabled: s.enabled,
    autoConfirm: s.auto_confirm,
    leadTimeValue: lead.value,
    leadTimeUnit: lead.unit,
    maxDaysAhead: String(s.max_days_ahead),
    slotInterval: String(s.slot_interval_minutes),
    buffer: String(s.buffer_minutes),
    maxConcurrent: String(s.max_concurrent_jobs),
    requireDeposit: s.require_deposit,
    depositType: s.deposit_type,
    depositPercent: s.deposit_type === 'percent' ? bpsToPercentInput(s.deposit_value) : '',
    depositCents: s.deposit_type === 'fixed' ? s.deposit_value : null,
    postalCodes: s.service_area_postal_codes.join(', '),
    bookingMessage: s.booking_message ?? '',
    cancellationPolicy: s.cancellation_policy ?? '',
    cancelHours: String(s.allow_client_cancel_hours),
    maxConcurrentShop: s.max_concurrent_shop === null ? '' : String(s.max_concurrent_shop),
    maxConcurrentMobile: s.max_concurrent_mobile === null ? '' : String(s.max_concurrent_mobile),
    countMemberAvailability: s.count_member_availability,
    allowMultiDay: s.allow_multi_day,
    multiDayMaxDays: String(s.multi_day_max_days),
    quoteSelfSchedule: s.quote_self_schedule,
    metaPixelId: s.meta_pixel_id ?? '',
    ga4MeasurementId: s.ga4_measurement_id ?? '',
  };
}

function BookingForm({ settings, canEdit }: { settings: BookingSettings; canEdit: boolean }) {
  const toast = useToast();
  const { shop } = useShop();
  const offersShop = shop.business_type !== 'mobile';
  const offersMobile = shop.business_type !== 'fixed';
  const update = useUpdateBookingSettings();
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors, isDirty },
  } = useForm<BookingInput, unknown, BookingValues>({
    resolver: zodResolver(bookingSchema),
    defaultValues: toInput(settings),
  });
  const requireDeposit = useWatch({ control, name: 'requireDeposit' });
  const depositType = useWatch({ control, name: 'depositType' });
  const postalText = useWatch({ control, name: 'postalCodes' });
  const postalCount = parsePostalCodes(postalText).length;
  const allowMultiDay = useWatch({ control, name: 'allowMultiDay' });

  const onSubmit = handleSubmit(async (v) => {
    const leadMinutes = joinMinutes(v.leadTimeValue, v.leadTimeUnit) ?? 0;
    try {
      const saved = await update.mutateAsync({
        enabled: v.enabled,
        auto_confirm: v.autoConfirm,
        lead_time_minutes: leadMinutes,
        max_days_ahead: v.maxDaysAhead,
        slot_interval_minutes: v.slotInterval,
        buffer_minutes: v.buffer,
        max_concurrent_jobs: v.maxConcurrent,
        require_deposit: v.requireDeposit,
        deposit_type: v.depositType,
        deposit_value: depositValueOf(v),
        service_area_postal_codes: parsePostalCodes(v.postalCodes),
        booking_message: v.bookingMessage,
        cancellation_policy: v.cancellationPolicy,
        allow_client_cancel_hours: v.cancelHours,
        max_concurrent_shop: v.maxConcurrentShop,
        max_concurrent_mobile: v.maxConcurrentMobile,
        count_member_availability: v.countMemberAvailability,
        allow_multi_day: v.allowMultiDay,
        multi_day_max_days: v.multiDayMaxDays,
        quote_self_schedule: v.quoteSelfSchedule,
        meta_pixel_id: v.metaPixelId,
        ga4_measurement_id: v.ga4MeasurementId,
      });
      reset(toInput(saved));
      toast.success('Booking settings saved');
    } catch (error) {
      toast.error(toAppError(error));
    }
  });

  return (
    <form onSubmit={(e) => void onSubmit(e)} noValidate className="flex flex-col gap-4">
      <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-4">
        <legend className="sr-only">Online booking settings</legend>
        <SectionCard title="Booking">
          <div className="flex flex-col gap-4">
            <Controller
              control={control}
              name="enabled"
              render={({ field }) => (
                <Switch
                  label="Accept online bookings"
                  description="Customers can pick services and a time on your booking page."
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  disabled={!canEdit}
                />
              )}
            />
            <Controller
              control={control}
              name="autoConfirm"
              render={({ field }) => (
                <Switch
                  label="Confirm bookings automatically"
                  description="Off: new bookings arrive as requests you approve. On: they go straight onto the schedule."
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  disabled={!canEdit}
                />
              )}
            />
            <Controller
              control={control}
              name="quoteSelfSchedule"
              render={({ field }) => (
                <Switch
                  label="Customers can schedule approved quotes"
                  description="After approving a quote online, the customer picks a time (and pays any deposit) using the rules below. You can turn it off per quote."
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  disabled={!canEdit}
                />
              )}
            />
          </div>
        </SectionCard>

        <SectionCard
          title="Availability"
          description="Rules the booking page uses to offer start times."
        >
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField
              label="Minimum notice"
              error={errors.leadTimeValue?.message}
              help="How far in advance customers must book."
            >
              <div className="flex gap-2">
                <Input
                  inputMode="numeric"
                  className="min-w-0 flex-1"
                  {...register('leadTimeValue')}
                />
                <Select
                  aria-label="Minimum notice unit"
                  className="w-32 shrink-0"
                  options={DURATION_UNITS.map((u) => ({ value: u, label: UNIT_LABELS[u] }))}
                  {...register('leadTimeUnit')}
                />
              </div>
            </FormField>
            <FormField
              label="Booking window (days ahead)"
              error={errors.maxDaysAhead?.message}
              help="How far into the future customers can book (1–365)."
            >
              <Input inputMode="numeric" {...register('maxDaysAhead')} />
            </FormField>
            <FormField
              label="Start time interval (minutes)"
              error={errors.slotInterval?.message}
              help="Offer start times every N minutes, e.g. 30 → 9:00, 9:30 (5–240)."
            >
              <Input inputMode="numeric" {...register('slotInterval')} />
            </FormField>
            <FormField
              label="Buffer between jobs (minutes)"
              error={errors.buffer?.message}
              help="Clean-up or travel time kept free after each job (0–480)."
            >
              <Input inputMode="numeric" {...register('buffer')} />
            </FormField>
            <FormField
              label="Jobs at the same time"
              error={errors.maxConcurrent?.message}
              help="How many online bookings can overlap (1–100)."
            >
              <Input inputMode="numeric" {...register('maxConcurrent')} />
            </FormField>
            {offersShop && shop.business_type === 'both' && (
              <FormField
                label="In-shop jobs at the same time"
                error={errors.maxConcurrentShop?.message}
                help="Optional lower limit for jobs at your shop (bays). Empty = the overall limit."
              >
                <Input inputMode="numeric" {...register('maxConcurrentShop')} />
              </FormField>
            )}
            {offersMobile && shop.business_type === 'both' && (
              <FormField
                label="Mobile jobs at the same time"
                error={errors.maxConcurrentMobile?.message}
                help="Optional lower limit for jobs at customers’ addresses (vans). Empty = the overall limit."
              >
                <Input inputMode="numeric" {...register('maxConcurrentMobile')} />
              </FormField>
            )}
            <div className="sm:col-span-2">
              <Controller
                control={control}
                name="countMemberAvailability"
                render={({ field }) => (
                  <Switch
                    label="Count technicians’ availability"
                    description="Also limit bookings to the number of team members who take online bookings and aren’t off or busy (set per member in Team)."
                    checked={field.value}
                    onCheckedChange={field.onChange}
                    disabled={!canEdit}
                  />
                )}
              />
            </div>
            <div className="flex flex-col gap-3 sm:col-span-2">
              <Controller
                control={control}
                name="allowMultiDay"
                render={({ field }) => (
                  <Switch
                    label="Allow multi-day bookings"
                    description="A service longer than the opening hours left that day (e.g. a coating) continues the next open day instead of being unbookable."
                    checked={field.value}
                    onCheckedChange={field.onChange}
                    disabled={!canEdit}
                  />
                )}
              />
              {allowMultiDay && (
                <FormField
                  label="Longest booking (days)"
                  error={errors.multiDayMaxDays?.message}
                  help="2–7 days."
                  className="max-w-xs"
                >
                  <Input inputMode="numeric" {...register('multiDayMaxDays')} />
                </FormField>
              )}
            </div>
            <FormField
              label="Service area postal codes"
              error={errors.postalCodes?.message}
              help={
                postalCount === 0
                  ? 'Leave empty to accept any address. Separate codes with commas or new lines.'
                  : `${postalCount} postal code${postalCount === 1 ? '' : 's'}. Mobile bookings outside them are refused.`
              }
              className="sm:col-span-2"
            >
              <Textarea rows={3} {...register('postalCodes')} />
            </FormField>
          </div>
        </SectionCard>

        <SectionCard title="Deposit" description="Collected by card when a customer books online.">
          <div className="flex flex-col gap-4">
            <Controller
              control={control}
              name="requireDeposit"
              render={({ field }) => (
                <Switch
                  label="Require a deposit to book"
                  description="Needs Stripe connected in Settings → Payments."
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  disabled={!canEdit}
                />
              )}
            />
            {requireDeposit && (
              <div className="grid gap-4 sm:grid-cols-2">
                <Controller
                  control={control}
                  name="depositType"
                  render={({ field }) => (
                    <RadioGroup
                      label="Deposit type"
                      value={field.value}
                      onChange={field.onChange}
                      options={[
                        { value: 'percent', label: 'Percent of the booking total' },
                        { value: 'fixed', label: 'Fixed amount' },
                      ]}
                      disabled={!canEdit}
                    />
                  )}
                />
                {depositType === 'percent' ? (
                  <FormField
                    label="Deposit percent"
                    required
                    error={errors.depositPercent?.message}
                  >
                    <Input inputMode="decimal" trailing="%" {...register('depositPercent')} />
                  </FormField>
                ) : (
                  <FormField label="Deposit amount" required error={errors.depositCents?.message}>
                    <Controller
                      control={control}
                      name="depositCents"
                      render={({ field }) => (
                        <MoneyInput
                          value={field.value}
                          onChange={field.onChange}
                          onBlur={field.onBlur}
                          name={field.name}
                          ref={field.ref}
                        />
                      )}
                    />
                  </FormField>
                )}
              </div>
            )}
          </div>
        </SectionCard>

        <SectionCard
          title="Tracking"
          description="Measure your ads: your public booking page loads these tags only when you fill them in. They see page views, the start of a booking and each booking with its value (Google Analytics also sees deposits paid online) — we never give them names, emails, phone numbers or booking links."
        >
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField
              label="Meta (Facebook) Pixel ID"
              error={errors.metaPixelId?.message}
              help="Digits only, from Meta Events Manager."
            >
              <Input inputMode="numeric" autoComplete="off" {...register('metaPixelId')} />
            </FormField>
            <FormField
              label="Google Analytics 4 measurement ID"
              error={errors.ga4MeasurementId?.message}
              help="Looks like G-XXXXXXXXXX (Admin → Data streams)."
            >
              <Input autoComplete="off" className="uppercase" {...register('ga4MeasurementId')} />
            </FormField>
          </div>
          <p className="text-muted mt-3 text-xs">
            Adding these tags lets Meta or Google set cookies on your booking page; mention them in
            your website’s privacy policy. In Meta Events Manager, keep “Automatic advanced
            matching” off for this pixel: it lets Meta pick up the contact details customers type
            into the booking form.
          </p>
        </SectionCard>

        <SectionCard title="Messages & cancellations">
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField
              label="Booking page message"
              error={errors.bookingMessage?.message}
              help="Shown at the top of your booking page."
              className="sm:col-span-2"
            >
              <Textarea rows={3} {...register('bookingMessage')} />
            </FormField>
            <FormField
              label="Cancellation policy"
              error={errors.cancellationPolicy?.message}
              help="Customers see this before they book and when they manage a booking."
              className="sm:col-span-2"
            >
              <Textarea rows={3} {...register('cancellationPolicy')} />
            </FormField>
            <FormField
              label="Customers can cancel up to (hours before)"
              error={errors.cancelHours?.message}
              help="0 lets customers cancel online until the appointment starts."
            >
              <Input inputMode="numeric" {...register('cancelHours')} />
            </FormField>
          </div>
        </SectionCard>
      </fieldset>
      {canEdit && (
        <FormActions
          dirty={isDirty}
          saving={update.isPending}
          onDiscard={() => reset(toInput(settings))}
        />
      )}
    </form>
  );
}
