import { CalendarCheck2, CreditCard, Hourglass } from 'lucide-react';
import { useEffect, useRef } from 'react';
import { Button, Card, CardBody, KeyValueList, StatusBadge, buttonClasses } from '@/components/ui';
import { formatInTz, formatTimeRange } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { timeZoneName } from '@/features/public-docs/shared/format';
import { useDepositCheckout, type CreatedBooking, type ShopProfile } from '../api';
import type { SlotChoice } from '../model';
import { PublicLink } from './PublicLink';

export function Confirmation({
  profile,
  created,
  slot,
  embed = false,
}: {
  profile: ShopProfile;
  created: CreatedBooking;
  slot: SlotChoice | null;
  /** Inside a shop's website: leave the frame for the booking page (and pay there). */
  embed?: boolean;
}) {
  const headingRef = useRef<HTMLHeadingElement>(null);
  const deposit = useDepositCheckout(created.job_token);
  const currency = profile.currency;
  const tz = profile.timezone;
  const confirmed = created.status !== 'requested';
  const depositDue = created.deposit_required_cents > 0;
  const manageHref = `/booking/${created.job_token}`;

  useEffect(() => {
    headingRef.current?.focus();
  }, []);

  return (
    <Card as="section" aria-labelledby="booking-confirmation-title">
      <CardBody className="flex flex-col items-center gap-3 py-8 text-center">
        <div
          className={
            confirmed
              ? 'bg-success-soft text-success-ink flex size-12 items-center justify-center rounded-full'
              : 'bg-warning-soft text-warning-ink flex size-12 items-center justify-center rounded-full'
          }
        >
          {confirmed ? (
            <CalendarCheck2 className="size-6" aria-hidden="true" />
          ) : (
            <Hourglass className="size-6" aria-hidden="true" />
          )}
        </div>
        <h2
          id="booking-confirmation-title"
          ref={headingRef}
          tabIndex={-1}
          className="text-ink text-xl font-semibold outline-none"
        >
          {confirmed ? 'You’re booked!' : 'Request received'}
        </h2>
        <p className="text-muted max-w-md text-sm">
          {confirmed
            ? `Your appointment with ${profile.name} is confirmed.`
            : `${profile.name} will review your request and confirm your appointment.`}{' '}
          Keep your booking link to view, pay or cancel later.
        </p>
      </CardBody>
      <CardBody className="border-line flex flex-col gap-4 border-t">
        <KeyValueList
          items={[
            { key: 'number', label: 'Booking number', value: `#${created.job_number}` },
            {
              key: 'status',
              label: 'Status',
              value: <StatusBadge kind="job" status={created.status} />,
            },
            ...(slot
              ? [
                  {
                    key: 'when',
                    label: 'When',
                    value: (
                      <>
                        {formatInTz(slot.startsAt, tz, 'EEE, MMM d, yyyy')} ·{' '}
                        {formatTimeRange(slot.startsAt, slot.endsAt, tz)}
                        <span className="text-muted block text-xs">
                          {timeZoneName(tz, new Date(slot.startsAt))}
                        </span>
                      </>
                    ),
                  },
                ]
              : []),
            {
              key: 'total',
              label: 'Total',
              value: formatCents(created.total_cents, { currency }),
              emphasis: true,
            },
            ...(depositDue
              ? [
                  {
                    key: 'deposit',
                    label: 'Deposit required',
                    value: (
                      <span className="text-money-ink">
                        {formatCents(created.deposit_required_cents, { currency })}
                      </span>
                    ),
                  },
                ]
              : []),
          ]}
        />
        {deposit.isError && (
          <Banner tone="danger" title="Couldn’t open the payment page">
            {errorMessage(deposit.error)} You can also pay from your booking page.
          </Banner>
        )}
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          {embed ? (
            <a
              href={manageHref}
              target="_top"
              className={buttonClasses({
                variant: depositDue ? 'money' : 'secondary',
                size: 'lg',
              })}
            >
              {depositDue ? (
                <>
                  <CreditCard className="size-4" aria-hidden="true" />
                  Pay {formatCents(created.deposit_required_cents, { currency })} deposit
                </>
              ) : (
                'View or manage booking'
              )}
            </a>
          ) : (
            // A full page load while the shop's tag is loaded: the booking
            // link is the customer's credential (tracking.ts).
            <PublicLink
              to={manageHref}
              className={buttonClasses({ variant: 'secondary', size: 'lg' })}
            >
              View or manage booking
            </PublicLink>
          )}
          {depositDue && !embed && (
            <Button
              variant="money"
              size="lg"
              loading={deposit.isPending || deposit.isSuccess}
              onClick={() => deposit.mutate()}
              leadingIcon={<CreditCard className="size-4" aria-hidden="true" />}
            >
              Pay {formatCents(created.deposit_required_cents, { currency })} deposit
            </Button>
          )}
        </div>
        {depositDue && (
          <p className="text-muted text-xs">
            A deposit is required for this booking. Payments are processed securely by Stripe
            {embed ? ' on your booking page' : ''}.
          </p>
        )}
      </CardBody>
    </Card>
  );
}
