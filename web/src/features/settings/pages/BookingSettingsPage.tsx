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
  };
}

function BookingForm({ settings, canEdit }: { settings: BookingSettings; canEdit: boolean }) {
  const toast = useToast();
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
