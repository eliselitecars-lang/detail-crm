import { CalendarOff, Link2Off, Phone } from 'lucide-react';
import { useEffect, useState, type ReactNode } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import { Card, EmptyState, ErrorState, LoadingState, buttonClasses } from '@/components/ui';
import { shopToday } from '@/lib/dates';
import { errorMessage, sentenceCase, toAppError } from '@/lib/errors';
import { formatPhone } from '@/lib/phone';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { toBranding } from '@/features/public-docs/shared/schemas';
import {
  useBookingCatalog,
  useBookingLink,
  useBookingQuestions,
  useCreateBooking,
  useShopProfile,
  useValidateCoupon,
  type BookingCatalog,
  type BookingLink,
  type BookingQuestion,
  type CreatedBooking,
  type ShopProfile,
} from './api';
import { BookingPageLink } from './components/BookingPageLink';
import { Confirmation } from './components/Confirmation';
import { DetailsStep } from './components/DetailsStep';
import { EmbedFrame } from './components/EmbedFrame';
import { ReviewStep } from './components/ReviewStep';
import { ServicesStep } from './components/ServicesStep';
import { StepIndicator } from './components/StepIndicator';
import { TimeStep } from './components/TimeStep';
import { VehicleStep } from './components/VehicleStep';
import {
  applyPrefill,
  buildPayload,
  classifyBookingError,
  initialWizardState,
  locationFor,
  PREFILL_PARAMS,
  pruneSelection,
  readPrefill,
  STEPS,
  visibleQuestions,
  weekdayRestriction,
  type BookingPrefill,
  type StepId,
  type WizardState,
} from './model';
import { requestEmbedScrollTop } from './embed';
import {
  hasTracking,
  initTracking,
  stopTracking,
  trackEvent,
  useTrackingActive,
  validTrackingIds,
} from './tracking';

export default function BookingPage() {
  const { slug = '' } = useParams();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  // Read once: the wizard owns these values afterwards.
  const [prefill] = useState<BookingPrefill>(() => readPrefill(params));
  const embed = prefill.embed;
  const profile = useShopProfile(slug);

  // Coupon / service pre-selection now lives in the wizard; drop it from the
  // address bar so analytics tags and copied URLs never carry a code.
  useEffect(() => {
    if (!PREFILL_PARAMS.some((name) => params.has(name))) return;
    const next = new URLSearchParams(params);
    for (const name of PREFILL_PARAMS) next.delete(name);
    const search = next.toString();
    void navigate({ search: search ? `?${search}` : '' }, { replace: true });
  }, [params, navigate]);

  if (profile.isPending) {
    return (
      <BookingFrame profile={null} embed={embed}>
        <Card>
          <LoadingState label="Loading booking…" />
        </Card>
      </BookingFrame>
    );
  }
  if (profile.isError) {
    return (
      <BookingFrame profile={null} embed={embed}>
        <Card>
          {toAppError(profile.error).kind === 'not_found' ? (
            <EmptyState
              icon={<Link2Off aria-hidden="true" />}
              title="We couldn’t find this booking page"
              description="The link may be incomplete or no longer valid. Check the link, or contact the shop."
            />
          ) : (
            <ErrorState
              error={profile.error}
              title="Couldn’t load this booking page"
              onRetry={() => void profile.refetch()}
              retrying={profile.isFetching}
            />
          )}
        </Card>
      </BookingFrame>
    );
  }
  if (!profile.data.booking.enabled) {
    return <BookingClosed profile={profile.data} embed={embed} />;
  }
  return <BookingWizardLoader slug={slug} profile={profile.data} prefill={prefill} />;
}

/** PublicLayout, or the chrome-less frame when embedded in a shop's website. */
function BookingFrame({
  profile,
  embed,
  children,
}: {
  profile: ShopProfile | null;
  embed: boolean;
  children: ReactNode;
}) {
  const tracking = useTrackingActive();
  if (embed) {
    return (
      <EmbedFrame brandColor={profile?.brand_color} title="Book online" shopName={profile?.name}>
        {children}
      </EmbedFrame>
    );
  }
  return (
    <PublicLayout
      shop={profile ? toBranding(profile) : null}
      title="Book online"
      width="wide"
      fullPageLinks={tracking}
    >
      {children}
    </PublicLayout>
  );
}

function PageHeading({ profile, link }: { profile: ShopProfile; link?: BookingLink | null }) {
  const place = [profile.city, profile.region].filter(Boolean).join(', ');
  return (
    <div className="mb-4 sm:mb-6">
      <h1 className="text-ink text-xl font-semibold sm:text-2xl">
        {link ? link.name : `Book with ${profile.name}`}
      </h1>
      {link ? (
        <p className="text-muted mt-1 text-sm">
          {[profile.name, place].filter(Boolean).join(' · ')}
        </p>
      ) : (
        place && <p className="text-muted mt-1 text-sm">{place}</p>
      )}
      {link?.note && <p className="text-ink mt-2 text-sm whitespace-pre-line">{link.note}</p>}
    </div>
  );
}

function BookingClosed({
  profile,
  message,
  embed,
}: {
  profile: ShopProfile;
  message?: string;
  embed: boolean;
}) {
  return (
    <BookingFrame profile={profile} embed={embed}>
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
    </BookingFrame>
  );
}

/** A private link that no longer works (unknown, switched off, expired, another shop's). */
function LinkUnavailable({ profile, embed }: { profile: ShopProfile; embed: boolean }) {
  return (
    <BookingFrame profile={profile} embed={embed}>
      <PageHeading profile={profile} />
      <Card>
        <EmptyState
          icon={<Link2Off aria-hidden="true" />}
          title="This booking link is no longer available"
          description="It may have expired or been switched off. You can still book the shop’s regular services."
          action={
            // A new document without a referrer: the booking page may load the
            // shop's tags, which must never see this page's ?link=<token>.
            <BookingPageLink
              slug={profile.slug}
              {...(embed ? { target: '_top' } : {})}
              className={buttonClasses({ variant: 'secondary' })}
            >
              See all services
            </BookingPageLink>
          }
        />
      </Card>
    </BookingFrame>
  );
}

function BookingWizardLoader({
  slug,
  profile,
  prefill,
}: {
  slug: string;
  profile: ShopProfile;
  prefill: BookingPrefill;
}) {
  const linkToken = prefill.linkToken;
  const embed = prefill.embed;
  const link = useBookingLink(linkToken);
  const regular = useBookingCatalog(slug, linkToken === null);
  const questions = useBookingQuestions(slug);

  // The shop's tags run on its public booking page only (never private links),
  // and only once the prefill parameters (a coupon code) are off the URL.
  const [params] = useSearchParams();
  const urlClean = !PREFILL_PARAMS.some((name) => params.has(name));
  const ids = validTrackingIds(profile.tracking);
  const tracking = linkToken === null && urlClean && hasTracking(ids);
  const { metaPixelId, ga4MeasurementId } = ids;
  useEffect(() => {
    if (!tracking) return;
    initTracking({ metaPixelId, ga4MeasurementId });
    trackEvent('page_view');
    // Leaving the booking page inside this document (links out are full page
    // loads while a tag is on; this also covers anything else): stop the tags.
    return () => stopTracking();
  }, [tracking, metaPixelId, ga4MeasurementId]);

  const catalogError = linkToken ? link.error : regular.error;
  if (catalogError && toAppError(catalogError).code === '55000') {
    return <BookingClosed profile={profile} embed={embed} />;
  }
  if (linkToken) {
    if (
      (link.isError && toAppError(link.error).kind === 'not_found') ||
      (link.data && link.data.slug !== profile.slug)
    ) {
      return <LinkUnavailable profile={profile} embed={embed} />;
    }
  }
  const catalog: BookingCatalog | undefined = linkToken ? link.data?.catalog : regular.data;
  const pending = (linkToken ? link.isPending : regular.isPending) || questions.isPending;
  if (!catalog || pending) {
    return (
      <BookingFrame profile={profile} embed={embed}>
        <PageHeading profile={profile} />
        <Card>
          {catalogError ? (
            <ErrorState
              error={catalogError}
              title="Couldn’t load services"
              onRetry={() => void (linkToken ? link.refetch() : regular.refetch())}
              retrying={linkToken ? link.isFetching : regular.isFetching}
            />
          ) : (
            <LoadingState label="Loading services…" />
          )}
        </Card>
      </BookingFrame>
    );
  }
  if (catalog.services.length === 0) {
    return (
      <BookingClosed
        profile={profile}
        embed={embed}
        message="No services can be booked online right now. Please contact the shop to book."
      />
    );
  }
  return (
    <BookingWizard
      slug={slug}
      profile={profile}
      catalog={catalog}
      link={linkToken ? (link.data ?? null) : null}
      linkToken={linkToken}
      // A failed questions request never blocks booking (the shop may have
      // none, and the server still checks required answers), but the details
      // step says so and offers Try again, so a required question can be
      // loaded and answered instead of dead-ending on "<label> is required".
      questions={questions.data ?? []}
      questionsProblem={
        questions.isError
          ? { retrying: questions.isFetching, onRetry: () => void questions.refetch() }
          : null
      }
      prefill={prefill}
      tracking={tracking}
    />
  );
}

interface StepNotice {
  step: StepId;
  message: string;
}

function BookingWizard({
  slug,
  profile,
  catalog,
  link,
  linkToken,
  questions,
  questionsProblem,
  prefill,
  tracking,
}: {
  slug: string;
  profile: ShopProfile;
  catalog: BookingCatalog;
  link: BookingLink | null;
  linkToken: string | null;
  questions: readonly BookingQuestion[];
  /** Set when the questions failed to load (see DetailsStep). */
  questionsProblem: { retrying: boolean; onRetry: () => void } | null;
  prefill: BookingPrefill;
  tracking: boolean;
}) {
  const embed = prefill.embed;
  const [state, setState] = useState<WizardState>(() =>
    applyPrefill(initialWizardState(profile), catalog, prefill),
  );
  const [step, setStep] = useState<StepId>('vehicle');
  const [reached, setReached] = useState<ReadonlySet<StepId>>(() => new Set(['vehicle']));
  const [weekStart, setWeekStart] = useState(() => shopToday(profile.timezone));
  const [notice, setNotice] = useState<StepNotice | null>(null);
  const [created, setCreated] = useState<CreatedBooking | null>(null);
  const [closed, setClosed] = useState(false);
  const create = useCreateBooking(slug);
  const prefillCoupon = useValidateCoupon(slug);

  // null when the shop has no vehicle categories: prices use each item's base price.
  const categoryId = state.vehicle.categoryId;
  const itemIds = [...state.serviceIds, ...state.addonIds];
  const location = locationFor(state.details, profile.business_type);
  const shownQuestions = visibleQuestions(questions, location);
  const labels = shownQuestions.map((q) => q.label);
  const classify = (error: unknown) =>
    classifyBookingError(error, labels, { questionsLoaded: questionsProblem === null });

  /**
   * A referral / promo code from the link is checked when the details step
   * first opens. It stays in the code input (state.couponPrefill) until it
   * is applied, so a rejected code, or a check that failed, is still there
   * to see, edit or apply again.
   */
  const applyCouponPrefill = () => {
    const code = state.couponPrefill;
    if (code === '' || state.details.couponCode !== '' || itemIds.length === 0) return;
    prefillCoupon.mutate(
      {
        serviceIds: itemIds,
        vehicleCategoryId: categoryId,
        code,
        locationType: location,
        linkToken,
      },
      {
        onSuccess: (preview) => {
          if (preview.valid) {
            setState((prev) => ({
              ...prev,
              couponPrefill: '',
              details: { ...prev.details, couponCode: preview.code ?? code },
            }));
          } else {
            setNotice({
              step: 'details',
              // sentenceCase ends the sentence.
              message: `Code ${code} can’t be used: ${sentenceCase(preview.message ?? 'it isn’t valid')}`,
            });
          }
        },
        onError: (error) => {
          setNotice({
            step: 'details',
            message: `We couldn’t check code ${code}: ${errorMessage(error)} Tap Apply to try again.`,
          });
        },
      },
    );
  };

  /** Brings the top of the page (or of the frame, when embedded) into view. */
  const scrollToTop = () => {
    if (embed) requestEmbedScrollTop();
    else window.scrollTo({ top: 0 });
  };

  const goTo = (next: StepId) => {
    setStep(next);
    setReached((prev) => new Set(prev).add(next));
    if (notice && notice.step !== next) setNotice(null);
    if (next === 'time' && !reached.has('time') && tracking) trackEvent('begin_checkout');
    if (next === 'details' && !reached.has('details')) applyCouponPrefill();
    // Leaving the details step: an unapplied code from the link was shown
    // (with why it wasn't applied); the input is the customer's from now on.
    if (step === 'details' && next !== 'details' && state.couponPrefill !== '') {
      setState((prev) => ({ ...prev, couponPrefill: '' }));
    }
    scrollToTop();
  };

  if (closed) return <BookingClosed profile={profile} embed={embed} />;

  if (created) {
    return (
      <BookingFrame profile={profile} embed={embed}>
        <PageHeading profile={profile} link={link} />
        <Confirmation profile={profile} created={created} slot={state.slot} embed={embed} />
      </BookingFrame>
    );
  }

  const book = () => {
    create.reset();
    setNotice(null);
    create.mutate(
      buildPayload(state, profile.business_type, { linkToken, questions: shownQuestions }),
      {
        onSuccess: (result) => {
          setCreated(result);
          if (tracking) {
            trackEvent('booking_created', {
              valueCents: result.total_cents,
              currency: profile.currency,
            });
          }
          scrollToTop();
        },
        onError: (error) => {
          const classified = classify(error);
          if (classified.kind === 'closed') {
            setClosed(true);
            return;
          }
          if (classified.kind === 'slot_taken') {
            setState((prev) => ({ ...prev, slot: null }));
          }
          if (classified.kind === 'coupon_not_checked') {
            // Take the code off the booking and leave it in the code input,
            // so Apply checks it again (or the customer removes it).
            setState((prev) => ({
              ...prev,
              couponPrefill: prev.details.couponCode,
              details: { ...prev.details, couponCode: '' },
            }));
          }
          if (classified.step) {
            goTo(classified.step);
            setNotice({ step: classified.step, message: classified.message });
            create.reset();
            // Probably an unanswered question we never showed: load them again.
            if (classified.step === 'details' && questionsProblem) questionsProblem.onRetry();
          }
        },
      },
    );
  };

  const stepNotice = (id: StepId) => (notice?.step === id ? notice.message : null);
  const reviewError =
    create.isError && step === 'review' ? (
      <Banner tone="danger" title="We couldn’t book this appointment">
        {classify(create.error).message}
      </Banner>
    ) : null;

  const stepIndex = STEPS.findIndex((s) => s.id === step);
  const back = () => {
    const previous = STEPS[stepIndex - 1];
    if (previous) goTo(previous.id);
  };

  return (
    <BookingFrame profile={profile} embed={embed}>
      <PageHeading profile={profile} link={link} />
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
            businessType={profile.business_type}
            locationType={location}
            onLocationChange={(locationType) =>
              setState((prev) => ({
                ...prev,
                details: { ...prev.details, locationType },
                slot: null,
              }))
            }
            linkToken={linkToken}
            restriction={weekdayRestriction(catalog, itemIds)}
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
            linkToken={linkToken}
            questions={shownQuestions}
            answers={state.answers}
            onAnswersChange={(answers) => setState((prev) => ({ ...prev, answers }))}
            couponPrefill={state.couponPrefill}
            couponChecking={prefillCoupon.isPending}
            notice={stepNotice('details')}
            questionsProblem={questionsProblem}
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
            linkToken={linkToken}
            questions={shownQuestions}
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
    </BookingFrame>
  );
}
