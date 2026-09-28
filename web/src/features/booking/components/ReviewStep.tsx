import { Pencil } from 'lucide-react';
import type { ReactNode } from 'react';
import { CustomFieldValues } from '@/components/customFields';
import { Button, ErrorState, KeyValueList, LoadingState } from '@/components/ui';
import { formatInTz, formatTimeRange } from '@/lib/dates';
import { formatBps, formatCents } from '@/lib/money';
import { formatPhone } from '@/lib/phone';
import { sentenceCase } from '@/lib/errors';
import { TotalsList } from '@/features/public-docs/shared/DocumentLines';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { timeZoneName } from '@/features/public-docs/shared/format';
import {
  usePricePreview,
  type BookingCatalog,
  type BookingQuestion,
  type ShopProfile,
} from '../api';
import { answersFor, locationFor, priceFor, type StepId, type WizardState } from '../model';
import { StepFrame } from './StepFrame';

export function ReviewStep({
  slug,
  profile,
  catalog,
  state,
  categoryId,
  linkToken,
  questions,
  error,
  submitting,
  onEdit,
  onRemoveCoupon,
  onBack,
  onBook,
}: {
  slug: string;
  profile: ShopProfile;
  catalog: BookingCatalog;
  state: WizardState;
  /** null when the shop has no vehicle categories. */
  categoryId: string | null;
  linkToken: string | null;
  /** The booking questions shown for this location. */
  questions: readonly BookingQuestion[];
  /** Booking failure that no earlier step can fix (shown here). */
  error: ReactNode;
  submitting: boolean;
  onEdit: (step: StepId) => void;
  onRemoveCoupon: () => void;
  onBack: () => void;
  onBook: () => void;
}) {
  const currency = profile.currency;
  const tz = profile.timezone;
  const itemIds = [...state.serviceIds, ...state.addonIds];
  const location = locationFor(state.details, profile.business_type);
  const preview = usePricePreview(slug, {
    serviceIds: itemIds,
    vehicleCategoryId: categoryId,
    code: state.details.couponCode,
    locationType: location,
    linkToken,
  });
  const answered = answersFor(questions, state.answers).answers;
  const couponRejected =
    state.details.couponCode !== '' && preview.data !== undefined && !preview.data.valid;

  const items = [
    ...state.serviceIds.map((id) => catalog.services.find((s) => s.id === id)),
    ...state.addonIds.map((id) => catalog.addons.find((a) => a.id === id)),
  ].filter((item) => item !== undefined);

  const { vehicle, details, slot } = state;
  const category = catalog.vehicle_categories.find((c) => c.id === vehicle.categoryId)?.name;
  const mobile = location === 'mobile';
  const booking = profile.booking;

  const depositText = !booking.require_deposit
    ? null
    : booking.deposit_type === 'percent' && booking.deposit_value !== null
      ? `A deposit of ${formatBps(booking.deposit_value)} of the total is required to secure your appointment.`
      : booking.deposit_type === 'fixed' && booking.deposit_value !== null
        ? `A deposit of ${formatCents(booking.deposit_value, { currency })} is required to secure your appointment.`
        : 'A deposit is required to secure your appointment.';

  const edit = (step: StepId, label: string) => (
    <Button
      variant="ghost"
      size="sm"
      onClick={() => onEdit(step)}
      leadingIcon={<Pencil className="size-3.5" aria-hidden="true" />}
    >
      Edit<span className="sr-only"> {label}</span>
    </Button>
  );

  return (
    <StepFrame
      title="Review and book"
      description={
        booking.auto_confirm
          ? 'Your appointment is confirmed as soon as you book.'
          : `This is a request — ${profile.name} will confirm your appointment.`
      }
      onBack={onBack}
      onContinue={onBook}
      continueLabel={booking.auto_confirm ? 'Book appointment' : 'Request appointment'}
      continueLoading={submitting}
      continueDisabled={couponRejected || preview.isPending}
    >
      {error}

      <ReviewSection title="Vehicle" action={edit('vehicle', 'vehicle')}>
        <p className="text-ink text-sm">
          {[vehicle.year, vehicle.make, vehicle.model].filter(Boolean).join(' ')}
          {vehicle.color ? ` · ${vehicle.color}` : ''}
          {category ? ` · ${category}` : ''}
        </p>
      </ReviewSection>

      <ReviewSection title="Services" action={edit('services', 'services')}>
        <ul className="flex flex-col gap-1">
          {items.map((item) => {
            const price = priceFor(item, vehicle.categoryId);
            return (
              <li key={item.id} className="flex items-baseline justify-between gap-3 text-sm">
                <span className="text-ink min-w-0 break-words">
                  {item.name}
                  {item.kind === 'addon' && <span className="text-muted"> (add-on)</span>}
                </span>
                <span className="text-ink shrink-0 tabular-nums">
                  {price ? formatCents(price.priceCents, { currency }) : '—'}
                </span>
              </li>
            );
          })}
        </ul>
      </ReviewSection>

      <ReviewSection title="Date & time" action={edit('time', 'date and time')}>
        {slot && (
          <p className="text-ink text-sm">
            {formatInTz(slot.startsAt, tz, 'EEEE, MMMM d, yyyy')} ·{' '}
            {formatTimeRange(slot.startsAt, slot.endsAt, tz)}{' '}
            <span className="text-muted">({timeZoneName(tz, new Date(slot.startsAt))})</span>
          </p>
        )}
      </ReviewSection>

      <ReviewSection title="Contact & location" action={edit('details', 'contact details')}>
        <KeyValueList
          items={[
            {
              key: 'name',
              label: 'Name',
              value: [details.firstName, details.lastName].filter(Boolean).join(' '),
            },
            { key: 'email', label: 'Email', value: details.email },
            {
              key: 'phone',
              label: 'Phone',
              value: details.phone ? formatPhone(details.phone) : null,
            },
            {
              key: 'where',
              label: 'Location',
              value: mobile
                ? [
                    details.addressLine1,
                    details.addressLine2,
                    [details.city, details.region, details.postalCode].filter(Boolean).join(', '),
                  ]
                    .filter(Boolean)
                    .join(', ')
                : 'At the shop',
            },
            ...(details.notes ? [{ key: 'notes', label: 'Notes', value: details.notes }] : []),
          ]}
        />
        {questions.length > 0 && Object.keys(answered).length > 0 && (
          <CustomFieldValues fields={questions} data={answered} className="mt-2" />
        )}
      </ReviewSection>

      <section aria-labelledby="review-estimate" className="flex flex-col gap-2">
        <h3 id="review-estimate" className="text-ink text-sm font-semibold">
          Estimated price
        </h3>
        {preview.isPending ? (
          <LoadingState label="Calculating…" />
        ) : preview.isError ? (
          <ErrorState
            compact
            error={preview.error}
            title="Couldn’t calculate the price"
            onRetry={() => void preview.refetch()}
            retrying={preview.isFetching}
          />
        ) : (
          <>
            {couponRejected && (
              <Banner
                tone="warning"
                title={`Coupon ${state.details.couponCode} can’t be used`}
                action={
                  <Button size="sm" variant="secondary" onClick={onRemoveCoupon}>
                    Remove code
                  </Button>
                }
              >
                {sentenceCase(preview.data.message ?? 'This coupon code is not valid')}
              </Banner>
            )}
            <TotalsList
              currency={currency}
              rows={[
                { key: 'subtotal', label: 'Subtotal', cents: preview.data.subtotal_cents },
                ...(preview.data.discount_cents > 0
                  ? [
                      {
                        key: 'discount',
                        label: `Discount (${state.details.couponCode})`,
                        cents: preview.data.discount_cents,
                        negative: true,
                      },
                    ]
                  : []),
                ...(preview.data.tax_cents > 0
                  ? [{ key: 'tax', label: 'Tax', cents: preview.data.tax_cents }]
                  : []),
                {
                  key: 'total',
                  label: 'Estimated total',
                  cents: preview.data.total_cents,
                  emphasis: true,
                },
              ]}
            />
            <p className="text-muted text-xs">Your confirmed total is shown after you book.</p>
          </>
        )}
      </section>

      {(depositText || booking.cancellation_policy || booking.booking_message) && (
        <div className="bg-surface-2 rounded-card flex flex-col gap-2 p-3 text-sm">
          {depositText && <p className="text-ink font-medium">{depositText}</p>}
          {booking.allow_client_cancel_hours !== null && booking.allow_client_cancel_hours > 0 && (
            <p className="text-muted">
              You can cancel online up to {booking.allow_client_cancel_hours} hours before your
              appointment.
            </p>
          )}
          {booking.cancellation_policy && (
            <p className="text-muted whitespace-pre-line">{booking.cancellation_policy}</p>
          )}
          {booking.booking_message && (
            <p className="text-muted whitespace-pre-line">{booking.booking_message}</p>
          )}
        </div>
      )}
    </StepFrame>
  );
}

function ReviewSection({
  title,
  action,
  children,
}: {
  title: string;
  action: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="border-line flex flex-col gap-1.5 border-b pb-4">
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-ink text-sm font-semibold">{title}</h3>
        {action}
      </div>
      {children}
    </section>
  );
}
