import { CalendarOff, Phone } from 'lucide-react';
import { useState } from 'react';
import { useParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import { Card, EmptyState, ErrorState, LoadingState, buttonClasses } from '@/components/ui';
import { shopToday } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { formatPhone } from '@/lib/phone';
import { Banner, PublicError, PublicLoading } from '@/features/public-docs/shared/PublicPage';
import { toBranding } from '@/features/public-docs/shared/schemas';
import {
  useBookingCatalog,
  useCreateBooking,
  useShopProfile,
  type BookingCatalog,
  type CreatedBooking,
  type ShopProfile,
} from './api';
import { Confirmation } from './components/Confirmation';
import { DetailsStep } from './components/DetailsStep';
import { ReviewStep } from './components/ReviewStep';
import { ServicesStep } from './components/ServicesStep';
import { StepIndicator } from './components/StepIndicator';
import { TimeStep } from './components/TimeStep';
import { VehicleStep } from './components/VehicleStep';
import {
  buildPayload,
  classifyBookingError,
  initialWizardState,
  pruneSelection,
  STEPS,
  type StepId,
  type WizardState,
} from './model';

export default function BookingPage() {
  const { slug = '' } = useParams();
  const profile = useShopProfile(slug);
  if (profile.isPending) return <PublicLoading label="Loading booking…" width="wide" />;
  if (profile.isError) {
    return (
      <PublicError
        error={profile.error}
        what="booking page"
        width="wide"
        onRetry={() => void profile.refetch()}
        retrying={profile.isFetching}
      />
    );
  }
  if (!profile.data.booking.enabled) return <BookingClosed profile={profile.data} />;
  return <BookingWizardLoader slug={slug} profile={profile.data} />;
}

function PageHeading({ profile }: { profile: ShopProfile }) {
  return (
    <div className="mb-4 sm:mb-6">
      <h1 className="text-ink text-xl font-semibold sm:text-2xl">Book with {profile.name}</h1>
      {[profile.city, profile.region].some(Boolean) && (
        <p className="text-muted mt-1 text-sm">
          {[profile.city, profile.region].filter(Boolean).join(', ')}
        </p>
      )}
    </div>
  );
}

function BookingClosed({ profile, message }: { profile: ShopProfile; message?: string }) {
  return (
    <PublicLayout shop={toBranding(profile)} width="wide">
      <PageHeading profile={profile} />
      <Card>
        <EmptyState
          icon={<CalendarOff aria-hidden="true" />}
          title="Online booking is closed right now"
          description={
            message ??
            (profile.phone
              ? `Please call ${formatPhone(profile.phone)} to book an appointment.`
              : 'Please contact the shop to book an appointment.')
          }
          {...(profile.phone
            ? {
                action: (
                  <a
                    href={`tel:${profile.phone}`}
                    className={buttonClasses({ variant: 'secondary' })}
                  >
                    <Phone className="size-4" aria-hidden="true" />
                    Call {formatPhone(profile.phone)}
                  </a>
                ),
              }
            : {})}
        />
      </Card>
    </PublicLayout>
  );
}

function BookingWizardLoader({ slug, profile }: { slug: string; profile: ShopProfile }) {
  const catalog = useBookingCatalog(slug, true);
  if (catalog.isError && toAppError(catalog.error).code === '55000') {
    return <BookingClosed profile={profile} />;
  }
  if (catalog.isPending || catalog.isError) {
    return (
      <PublicLayout shop={toBranding(profile)} width="wide">
        <PageHeading profile={profile} />
        <Card>
          {catalog.isPending ? (
            <LoadingState label="Loading services…" />
          ) : (
            <ErrorState
              error={catalog.error}
              title="Couldn’t load services"
              onRetry={() => void catalog.refetch()}
              retrying={catalog.isFetching}
            />
          )}
        </Card>
      </PublicLayout>
    );
  }
  if (catalog.data.services.length === 0) {
    return (
      <BookingClosed
        profile={profile}
        message="No services can be booked online right now. Please contact the shop to book."
      />
    );
  }
  return <BookingWizard slug={slug} profile={profile} catalog={catalog.data} />;
}

interface StepNotice {
  step: StepId;
  message: string;
}

function BookingWizard({
  slug,
  profile,
  catalog,
}: {
  slug: string;
  profile: ShopProfile;
  catalog: BookingCatalog;
}) {
  const [state, setState] = useState<WizardState>(() => initialWizardState(profile));
  const [step, setStep] = useState<StepId>('vehicle');
  const [reached, setReached] = useState<ReadonlySet<StepId>>(() => new Set(['vehicle']));
  const [weekStart, setWeekStart] = useState(() => shopToday(profile.timezone));
  const [notice, setNotice] = useState<StepNotice | null>(null);
  const [created, setCreated] = useState<CreatedBooking | null>(null);
  const [closed, setClosed] = useState(false);
  const create = useCreateBooking(slug);

  const goTo = (next: StepId) => {
    setStep(next);
    setReached((prev) => new Set(prev).add(next));
    if (notice && notice.step !== next) setNotice(null);
    window.scrollTo({ top: 0 });
  };

  // null when the shop has no vehicle categories: prices use each item's base price.
  const categoryId = state.vehicle.categoryId;
  const itemIds = [...state.serviceIds, ...state.addonIds];

  if (closed) return <BookingClosed profile={profile} />;

  if (created) {
    return (
      <PublicLayout shop={toBranding(profile)} width="wide">
        <PageHeading profile={profile} />
        <Confirmation profile={profile} created={created} slot={state.slot} />
      </PublicLayout>
    );
  }

  const book = () => {
    create.reset();
    setNotice(null);
    create.mutate(buildPayload(state, profile.business_type), {
      onSuccess: (result) => {
        setCreated(result);
        window.scrollTo({ top: 0 });
      },
      onError: (error) => {
        const classified = classifyBookingError(error);
        if (classified.kind === 'closed') {
          setClosed(true);
          return;
        }
        if (classified.kind === 'slot_taken') {
          setState((prev) => ({ ...prev, slot: null }));
        }
        if (classified.step) {
          goTo(classified.step);
          setNotice({ step: classified.step, message: classified.message });
          create.reset();
        }
      },
    });
  };

  const stepNotice = (id: StepId) => (notice?.step === id ? notice.message : null);
  const reviewError =
    create.isError && step === 'review' ? (
      <Banner tone="danger" title="We couldn’t book this appointment">
        {classifyBookingError(create.error).message}
      </Banner>
    ) : null;

  const stepIndex = STEPS.findIndex((s) => s.id === step);
  const back = () => {
    const previous = STEPS[stepIndex - 1];
    if (previous) goTo(previous.id);
  };

  return (
    <PublicLayout shop={toBranding(profile)} width="wide">
      <PageHeading profile={profile} />
      <div className="flex flex-col gap-4">
        <StepIndicator current={step} reachable={reached} onSelect={goTo} />
        {step === 'vehicle' && (
          <VehicleStep
            catalog={catalog}
            value={state.vehicle}
            onChange={(vehicle) =>
              setState((prev) => {
                if (vehicle.categoryId === prev.vehicle.categoryId) return { ...prev, vehicle };
                const pruned = pruneSelection(catalog, {
                  serviceIds: prev.serviceIds,
                  addonIds: prev.addonIds,
                  categoryId: vehicle.categoryId,
                });
                return { ...prev, vehicle, ...pruned, slot: null };
              })
            }
            onContinue={() => goTo('services')}
            notice={stepNotice('vehicle')}
          />
        )}
        {step === 'services' && (
          <ServicesStep
            catalog={catalog}
            currency={profile.currency}
            categoryId={state.vehicle.categoryId}
            serviceIds={state.serviceIds}
            addonIds={state.addonIds}
            onChange={(selection) => setState((prev) => ({ ...prev, ...selection, slot: null }))}
            onBack={back}
            onContinue={() => goTo('time')}
            notice={stepNotice('services')}
          />
        )}
        {step === 'time' && (
          <TimeStep
            slug={slug}
            timeZone={profile.timezone}
            maxDaysAhead={profile.booking.max_days_ahead}
            itemIds={itemIds}
            categoryId={categoryId}
            weekStart={weekStart}
            onWeekChange={setWeekStart}
            slot={state.slot}
            onSelect={(slot) => {
              setState((prev) => ({ ...prev, slot }));
              setNotice(null);
            }}
            notice={stepNotice('time')}
            onBack={back}
            onContinue={() => goTo('details')}
          />
        )}
        {step === 'details' && (
          <DetailsStep
            slug={slug}
            profile={profile}
            value={state.details}
            onChange={(details) => setState((prev) => ({ ...prev, details }))}
            itemIds={itemIds}
            categoryId={categoryId}
            notice={stepNotice('details')}
            onBack={back}
            onContinue={() => goTo('review')}
          />
        )}
        {step === 'review' && (
          <ReviewStep
            slug={slug}
            profile={profile}
            catalog={catalog}
            state={state}
            categoryId={categoryId}
            error={reviewError}
            submitting={create.isPending}
            onEdit={goTo}
            onRemoveCoupon={() =>
              setState((prev) => ({ ...prev, details: { ...prev.details, couponCode: '' } }))
            }
            onBack={back}
            onBook={book}
          />
        )}
      </div>
    </PublicLayout>
  );
}
