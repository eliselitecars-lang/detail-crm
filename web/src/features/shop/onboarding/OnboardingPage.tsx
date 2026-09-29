import { zodResolver } from '@hookform/resolvers/zod';
import { useQueryClient } from '@tanstack/react-query';
import { Check, LogOut } from 'lucide-react';
import { useMemo, useState, type ChangeEvent } from 'react';
import { Controller, useForm, useWatch } from 'react-hook-form';
import { Link, useNavigate } from 'react-router';
import { Logo } from '@/components/layout/Logo';
import {
  Button,
  Card,
  FormField,
  Input,
  PhoneInput,
  RadioGroup,
  Select,
  useToast,
} from '@/components/ui';
import { useAuth } from '@/features/auth/authContext';
import { FormAlert } from '@/features/auth/FormAlert';
import { billingKeys, fetchShopEntitlement, useBillingPlans } from '@/features/billing/api';
import {
  BILLING_PATH,
  newShopTrialText,
  PRICING_PATH,
  type Entitlement,
} from '@/features/billing/model';
import { cn } from '@/lib/cn';
import { browserTimeZone, listTimeZones } from '@/lib/dates';
import { toAppError, type AppError } from '@/lib/errors';
import { shellKeys } from '@/lib/queryKeys';
import { defaultWeek, validateWeek, weekToRows } from '../businessHours';
import { BusinessHoursEditor } from '../components/BusinessHoursEditor';
import { useShopContext } from '../shopContext';
import { createShop, replaceBusinessHours, saveShopDetails } from './api';
import {
  onboardingSchema,
  slugify,
  STEP_FIELDS,
  type OnboardingInput,
  type OnboardingValues,
} from './schema';

const STEPS = ['Your business', 'Contact & location', 'Taxes & hours'] as const;

const BUSINESS_TYPE_OPTIONS = [
  { value: 'fixed', label: 'At my shop', description: 'Customers bring vehicles to you.' },
  { value: 'mobile', label: 'Mobile', description: 'You go to the customer.' },
  { value: 'both', label: 'Both', description: 'Shop appointments and mobile jobs.' },
] as const;

export default function OnboardingPage() {
  const { user, signOut } = useAuth();
  const { memberships, switchShop, refetch } = useShopContext();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const toast = useToast();
  const [step, setStep] = useState(0);
  const [slugEdited, setSlugEdited] = useState(false);
  const [createdShopId, setCreatedShopId] = useState<string | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const timeZones = useMemo(() => {
    const zones = listTimeZones();
    const local = browserTimeZone();
    return zones.includes(local) ? zones : [local, ...zones];
  }, []);

  const {
    register,
    control,
    handleSubmit,
    trigger,
    setValue,
    setError,
    getValues,
    formState: { errors, isSubmitting },
  } = useForm<OnboardingInput, unknown, OnboardingValues>({
    resolver: zodResolver(onboardingSchema),
    mode: 'onTouched',
    defaultValues: {
      name: '',
      slug: '',
      businessType: 'fixed',
      timezone: browserTimeZone(),
      phone: '',
      email: user?.email ?? '',
      addressLine1: '',
      addressLine2: '',
      city: '',
      region: '',
      postalCode: '',
      taxRate: '0',
      hours: defaultWeek(),
    },
  });

  const slug = useWatch({ control, name: 'slug' });
  const hours = useWatch({ control, name: 'hours' });
  const hourErrors = errors.hours ? validateWeek(hours) : {};

  const goNext = async () => {
    const fields = STEP_FIELDS[step];
    if (fields && (await trigger([...fields], { shouldFocus: true })))
      setStep((s) => Math.min(s + 1, 2));
  };

  // Billing on = the platform offers plans ([] while billing is off).
  const plans = useBillingPlans();
  const billingOn = (plans.data?.length ?? 0) > 0;

  /** The new shop's standing, or null (unknown: Settings > Billing shows it). */
  const newShopEntitlement = async (shopId: string): Promise<Entitlement | null> => {
    try {
      return await queryClient.fetchQuery({
        queryKey: billingKeys.entitlement(shopId),
        queryFn: () => fetchShopEntitlement(shopId),
      });
    } catch {
      return null; // never block finishing setup
    }
  };

  const finish = async (shopId: string, timezone: string) => {
    const entitlement = await newShopEntitlement(shopId);
    switchShop(shopId);
    await queryClient.invalidateQueries({ queryKey: shellKeys.memberships(user?.id ?? '') });
    await refetch();
    if (entitlement?.billing_enabled && entitlement.state === 'lapsed') {
      // The free trial is once per person (0120): a second shop starts
      // without one, so new work waits for a plan. Go straight to choosing
      // one instead of meeting "subscription is inactive" on every screen.
      toast.success(
        'Your shop is ready',
        'The free trial was already used, so choose a plan to start adding customers and jobs.',
      );
      await navigate(BILLING_PATH, { replace: true });
      return;
    }
    const trial = newShopTrialText(entitlement, timezone);
    toast.success(
      'Your shop is ready',
      trial
        ? `${trial} Next: add your services and prices in Catalog.`
        : 'Next: add your services and prices in Catalog.',
    );
    await navigate('/app', { replace: true });
  };

  /** Shows a booking-link problem on step 1's slug field; false if `error` isn't one. */
  const showBookingLinkError = (error: AppError, fromCreateShop: boolean): boolean => {
    const taken =
      error.code === '23505' && (fromCreateShop || /slug/i.test(error.constraint ?? ''));
    // create_shop raises readable slug messages (reserved, invalid format).
    const invalid = fromCreateShop && /slug|link/i.test(error.message);
    if (!taken && !invalid) return false;
    setStep(0);
    setError('slug', {
      message: taken ? 'That booking link is taken. Try another.' : error.message,
    });
    return true;
  };

  const onSubmit = handleSubmit(async (values) => {
    setSubmitError(null);
    let shopId = createdShopId;
    if (!shopId) {
      try {
        shopId = await createShop(values);
        setCreatedShopId(shopId);
      } catch (error) {
        const appError = toAppError(error);
        if (!showBookingLinkError(appError, true)) setSubmitError(appError.message);
        return;
      }
    }
    try {
      // On a retry this also saves edits made to steps 1–2 since the shop was created.
      await saveShopDetails(shopId, values);
      await replaceBusinessHours(shopId, weekToRows(values.hours));
    } catch (error) {
      const appError = toAppError(error);
      if (showBookingLinkError(appError, false)) return;
      setSubmitError(
        `Your shop was created, but some settings didn’t save: ${appError.message} ` +
          'Try again, or skip and finish later in Settings.',
      );
      return;
    }
    await finish(shopId, values.timezone);
  });

  return (
    <div className="bg-canvas min-h-dvh">
      <header className="border-line bg-surface border-b">
        <div className="mx-auto flex h-14 max-w-3xl items-center justify-between px-4">
          <Logo />
          <div className="flex items-center gap-2">
            {memberships.length > 0 && (
              <Link to="/app" className="text-muted hover:text-ink text-sm font-medium">
                Back to app
              </Link>
            )}
            <Button
              variant="ghost"
              size="sm"
              leadingIcon={<LogOut className="size-4" aria-hidden="true" />}
              onClick={() => void signOut()}
            >
              Sign out
            </Button>
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-4 py-8">
        <h1 className="text-ink text-2xl font-semibold tracking-tight">Set up your shop</h1>
        <p className="text-muted mt-1 text-sm">
          A few details so bookings, invoices and reminders look right. You can change everything
          later.
        </p>
        {billingOn && (
          <p className="text-muted mt-2 text-sm">
            Compare plans on the{' '}
            <Link to={PRICING_PATH} className="text-primary-ink font-medium hover:underline">
              pricing page
            </Link>
            . Your shop’s trial and subscription are under Settings › Billing.
          </p>
        )}
        {memberships.length === 0 && (
          <p className="text-muted mt-2 text-sm">
            Booked a service with a shop? Your appointments are in the{' '}
            <Link to="/portal" className="text-primary-ink font-medium hover:underline">
              customer portal
            </Link>
            .
          </p>
        )}

        <ol className="mt-6 flex flex-wrap gap-x-6 gap-y-2" aria-label="Setup steps">
          {STEPS.map((label, index) => (
            <li
              key={label}
              aria-current={index === step ? 'step' : undefined}
              className={cn(
                'flex items-center gap-2 text-sm',
                index === step ? 'text-ink font-semibold' : 'text-muted',
              )}
            >
              <span
                className={cn(
                  'flex size-6 items-center justify-center rounded-full text-xs font-semibold',
                  index < step
                    ? 'bg-success text-white'
                    : index === step
                      ? 'bg-primary text-primary-fg'
                      : 'bg-surface-3 text-muted',
                )}
                aria-hidden="true"
              >
                {index < step ? <Check className="size-3.5" /> : index + 1}
              </span>
              {label}
              {index < step && <span className="sr-only">(done)</span>}
            </li>
          ))}
        </ol>

        <Card padded className="mt-5">
          <form
            noValidate
            onSubmit={(event) => {
              if (step < 2) {
                event.preventDefault();
                void goNext();
                return;
              }
              void onSubmit(event);
            }}
            className="flex flex-col gap-5"
          >
            <h2 className="text-ink text-base font-semibold">{STEPS[step]}</h2>
            {submitError && <FormAlert>{submitError}</FormAlert>}

            {step === 0 && (
              <>
                <FormField label="Shop name" error={errors.name?.message} required>
                  <Input
                    autoComplete="organization"

                    {...register('name', {
                      onChange: (event: ChangeEvent<HTMLInputElement>) => {
                        if (!slugEdited) {
                          setValue('slug', slugify(event.target.value), {
                            shouldValidate: slug !== '',
                          });
                        }
                      },
                    })}
                  />
                </FormField>
                <FormField
                  label="Booking link"
                  error={errors.slug?.message}
                  help={`Customers book at ${window.location.host}/book/${slug || 'your-shop'}`}
                  required
                >
                  <Input
                    autoComplete="off"
                    spellCheck={false}
                    {...register('slug', {
                      onChange: (event: ChangeEvent<HTMLInputElement>) => {
                        setSlugEdited(true);
                        const cleaned = event.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '');
                        if (cleaned !== event.target.value)
                          setValue('slug', cleaned, { shouldValidate: true });
                      },
                    })}
                  />
                </FormField>
                <Controller
                  control={control}
                  name="businessType"
                  render={({ field }) => (
                    <RadioGroup
                      label="Where do you work on vehicles?"
                      variant="cards"
                      orientation="horizontal"
                      value={field.value}
                      onChange={field.onChange}
                      options={BUSINESS_TYPE_OPTIONS}
                      error={errors.businessType?.message}
                    />
                  )}
                />
              </>
            )}

            {step === 1 && (
              <>
                <FormField
                  label="Time zone"
                  error={errors.timezone?.message}
                  help="Appointments, reminders and reports use this time zone."
                  required
                >
                  <Select {...register('timezone')}>
                    {timeZones.map((zone) => (
                      <option key={zone} value={zone}>
                        {zone.replace(/_/g, ' ')}
                      </option>
                    ))}
                  </Select>
                </FormField>
                <div className="grid gap-4 sm:grid-cols-2">
                  <FormField label="Business phone" error={errors.phone?.message}>
                    <Controller
                      control={control}
                      name="phone"
                      render={({ field }) => (
                        <PhoneInput
                          name={field.name}
                          ref={field.ref}
                          value={field.value}
                          onChange={field.onChange}
                          onBlur={field.onBlur}
                        />
                      )}
                    />
                  </FormField>
                  <FormField label="Business email" error={errors.email?.message}>
                    <Input type="email" autoComplete="email" {...register('email')} />
                  </FormField>
                </div>
                <FormField label="Street address" error={errors.addressLine1?.message}>
                  <Input autoComplete="address-line1" {...register('addressLine1')} />
                </FormField>
                <FormField label="Suite, unit (optional)" error={errors.addressLine2?.message}>
                  <Input autoComplete="address-line2" {...register('addressLine2')} />
                </FormField>
                <div className="grid gap-4 sm:grid-cols-3">
                  <FormField label="City" error={errors.city?.message}>
                    <Input autoComplete="address-level2" {...register('city')} />
                  </FormField>
                  <FormField label="State" error={errors.region?.message}>
                    <Input autoComplete="address-level1" {...register('region')} />
                  </FormField>
                  <FormField label="ZIP code" error={errors.postalCode?.message}>
                    <Input
                      autoComplete="postal-code"
                      inputMode="numeric"
                      {...register('postalCode')}
                    />
                  </FormField>
                </div>
              </>
            )}

            {step === 2 && (
              <>
                <FormField
                  label="Sales tax rate"
                  error={errors.taxRate?.message}
                  help="Applied to taxable services on quotes and invoices. Use 0 if you don’t charge tax."
                  className="max-w-48"
                >
                  <Input
                    inputMode="decimal"
                    trailing={<span className="text-muted pr-2 text-sm">%</span>}
                    {...register('taxRate')}
                  />
                </FormField>
                <div className="flex flex-col gap-2">
                  <div>
                    <h3 className="text-ink text-sm font-medium">Business hours</h3>
                    <p className="text-muted text-xs">
                      Online booking only offers times inside these hours.
                    </p>
                  </div>
                  <Controller
                    control={control}
                    name="hours"
                    render={({ field }) => (
                      <BusinessHoursEditor
                        value={field.value}
                        onChange={(next) => {
                          field.onChange(next);
                          if (errors.hours) void trigger('hours');
                        }}
                        errors={hourErrors}
                        disabled={isSubmitting}
                      />
                    )}
                  />
                  {errors.hours?.message && (
                    <p role="alert" className="text-danger-ink text-xs font-medium">
                      {errors.hours.message}
                    </p>
                  )}
                </div>
              </>
            )}

            <div className="border-line flex flex-col-reverse gap-2 border-t pt-4 sm:flex-row sm:justify-between">
              <div>
                {step > 0 && (
                  <Button
                    variant="ghost"
                    onClick={() => setStep((s) => s - 1)}
                    disabled={isSubmitting}
                  >
                    Back
                  </Button>
                )}
              </div>
              <div className="flex flex-col-reverse gap-2 sm:flex-row">
                {createdShopId && submitError && (
                  <Button
                    variant="secondary"
                    onClick={() => void finish(createdShopId, getValues('timezone'))}
                  >
                    Skip for now
                  </Button>
                )}
                <Button type="submit" loading={isSubmitting}>
                  {step < 2 ? 'Continue' : createdShopId ? 'Try again' : 'Create shop'}
                </Button>
              </div>
            </div>
          </form>
        </Card>
      </main>
    </div>
  );
}
