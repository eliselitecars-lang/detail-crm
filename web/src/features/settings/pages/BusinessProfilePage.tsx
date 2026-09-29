import { zodResolver } from '@hookform/resolvers/zod';
import { useMemo } from 'react';
import { Controller, useForm, useWatch } from 'react-hook-form';
import {
  FormField,
  Input,
  PhoneInput,
  RadioGroup,
  SectionCard,
  Select,
  useToast,
} from '@/components/ui';
import { listTimeZones } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { formatPhone } from '@/lib/phone';
import { useShopSettings, useUpdateShop, type ShopSettings } from '../api';
import { FormActions } from '../components/FormActions';
import { LogoCard } from '../components/LogoCard';
import {
  hasMailingAddress,
  MAILING_ADDRESS_MISSING,
  MAILING_ADDRESS_USE,
} from '../marketingAddress';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { businessSchema, HEX_COLOR_RE, type BusinessInput, type BusinessValues } from '../schemas';
import { useSettingsAccess } from '../useSettingsAccess';

const BUSINESS_TYPE_OPTIONS = [
  { value: 'fixed', label: 'At my shop', description: 'Customers bring vehicles to you.' },
  { value: 'mobile', label: 'Mobile', description: 'You go to the customer.' },
  { value: 'both', label: 'Both', description: 'Shop appointments and mobile jobs.' },
] as const;

export default function BusinessProfilePage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const query = useShopSettings();
  return (
    <SettingsSectionLayout section="business" readOnly={readOnly}>
      <QueryView query={query} label="your business profile">
        {(shop) => (
          <>
            <LogoCard shop={shop} canEdit={canEdit} />
            <BusinessForm key={shop.id} shop={shop} canEdit={canEdit} />
          </>
        )}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function toInput(shop: ShopSettings): BusinessInput {
  return {
    name: shop.name,
    phone: shop.phone ? formatPhone(shop.phone) : '',
    email: shop.email ?? '',
    website: shop.website ?? '',
    addressLine1: shop.address_line1 ?? '',
    addressLine2: shop.address_line2 ?? '',
    city: shop.city ?? '',
    region: shop.region ?? '',
    postalCode: shop.postal_code ?? '',
    country: shop.country,
    timezone: shop.timezone,
    businessType: shop.business_type,
    reviewUrl: shop.review_url ?? '',
    brandColor: shop.brand_color ?? '',
  };
}

function BusinessForm({ shop, canEdit }: { shop: ShopSettings; canEdit: boolean }) {
  const toast = useToast();
  const update = useUpdateShop();
  const timeZones = useMemo(() => {
    const zones = listTimeZones();
    return zones.includes(shop.timezone) ? zones : [shop.timezone, ...zones];
  }, [shop.timezone]);

  const {
    register,
    control,
    handleSubmit,
    reset,
    setValue,
    formState: { errors, isDirty },
  } = useForm<BusinessInput, unknown, BusinessValues>({
    resolver: zodResolver(businessSchema),
    defaultValues: toInput(shop),
  });
  const brandColor = useWatch({ control, name: 'brandColor' });
  const [addressLine1, city] = useWatch({ control, name: ['addressLine1', 'city'] });
  const mailingAddress = hasMailingAddress({ address_line1: addressLine1, city });

  const onSubmit = handleSubmit(async (values) => {
    try {
      const saved = await update.mutateAsync({
        name: values.name,
        phone: values.phone,
        email: values.email,
        website: values.website,
        address_line1: values.addressLine1,
        address_line2: values.addressLine2,
        city: values.city,
        region: values.region,
        postal_code: values.postalCode,
        country: values.country,
        timezone: values.timezone,
        business_type: values.businessType,
        review_url: values.reviewUrl,
        brand_color: values.brandColor,
      });
      reset(toInput(saved));
      toast.success('Business profile saved');
    } catch (error) {
      toast.error(toAppError(error));
    }
  });

  return (
    <form onSubmit={(e) => void onSubmit(e)} noValidate className="flex flex-col gap-4">
      <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-4">
        <legend className="sr-only">Business profile</legend>
        <SectionCard title="Business details">
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField
              label="Business name"
              required
              error={errors.name?.message}
              className="sm:col-span-2"
            >
              <Input autoComplete="organization" {...register('name')} />
            </FormField>
            <FormField label="Phone" error={errors.phone?.message}>
              <Controller
                control={control}
                name="phone"
                render={({ field }) => (
                  <PhoneInput
                    value={field.value}
                    onChange={field.onChange}
                    onBlur={field.onBlur}
                    name={field.name}
                    ref={field.ref}
                  />
                )}
              />
            </FormField>
            <FormField label="Email" error={errors.email?.message}>
              <Input type="email" autoComplete="email" {...register('email')} />
            </FormField>
            <FormField label="Website" error={errors.website?.message} className="sm:col-span-2">
              <Input type="url" inputMode="url" placeholder="https://" {...register('website')} />
            </FormField>
            <div className="sm:col-span-2">
              <Controller
                control={control}
                name="businessType"
                render={({ field }) => (
                  <RadioGroup
                    label="How you serve customers"
                    value={field.value}
                    onChange={field.onChange}
                    options={BUSINESS_TYPE_OPTIONS}
                    variant="cards"
                    disabled={!canEdit}
                  />
                )}
              />
            </div>
          </div>
        </SectionCard>

        <SectionCard
          title="Address & time zone"
          description={`${MAILING_ADDRESS_USE} Your time zone controls every date and time customers and staff see.`}
        >
          <div className="grid gap-4 sm:grid-cols-2">
            {!mailingAddress && (
              <p
                role="status"
                className="rounded-control bg-warning-soft text-warning-ink px-3 py-2 text-sm sm:col-span-2"
              >
                {MAILING_ADDRESS_MISSING}
              </p>
            )}
            <FormField
              label="Address line 1"
              error={errors.addressLine1?.message}
              className="sm:col-span-2"
            >
              <Input autoComplete="address-line1" {...register('addressLine1')} />
            </FormField>
            <FormField
              label="Address line 2"
              error={errors.addressLine2?.message}
              className="sm:col-span-2"
            >
              <Input autoComplete="address-line2" {...register('addressLine2')} />
            </FormField>
            <FormField label="City" error={errors.city?.message}>
              <Input autoComplete="address-level2" {...register('city')} />
            </FormField>
            <FormField label="State / region" error={errors.region?.message}>
              <Input autoComplete="address-level1" {...register('region')} />
            </FormField>
            <FormField label="Postal code" error={errors.postalCode?.message}>
              <Input autoComplete="postal-code" {...register('postalCode')} />
            </FormField>
            <FormField
              label="Country code"
              error={errors.country?.message}
              help="Two letters, like US."
            >
              <Input
                maxLength={2}
                autoComplete="country"
                className="uppercase"
                {...register('country')}
              />
            </FormField>
            <FormField
              label="Time zone"
              required
              error={errors.timezone?.message}
              className="sm:col-span-2"
            >
              <Select
                options={timeZones.map((zone) => ({ value: zone, label: zone.replace(/_/g, ' ') }))}
                {...register('timezone')}
              />
            </FormField>
          </div>
        </SectionCard>

        <SectionCard title="Brand & reviews">
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField
              label="Brand colour"
              error={errors.brandColor?.message}
              help="Used for buttons and accents on your booking page and customer links."
            >
              <div className="flex items-center gap-2">
                <input
                  type="color"
                  aria-label="Pick brand colour"
                  value={HEX_COLOR_RE.test(brandColor) ? brandColor : '#000000'}
                  onChange={(event) =>
                    setValue('brandColor', event.target.value.toUpperCase(), {
                      shouldDirty: true,
                      shouldValidate: true,
                    })
                  }
                  className="border-line-strong rounded-control h-9 w-12 shrink-0 cursor-pointer border bg-transparent p-0.5 disabled:cursor-not-allowed"
                />
                <Input
                  placeholder="#1F6FEB"
                  maxLength={7}
                  className="min-w-0 font-mono"
                  {...register('brandColor')}
                />
              </div>
            </FormField>
            <FormField
              label="Review link"
              error={errors.reviewUrl?.message}
              help="Where review-request messages send customers (e.g. your Google review page)."
            >
              <Input type="url" inputMode="url" placeholder="https://" {...register('reviewUrl')} />
            </FormField>
          </div>
        </SectionCard>
      </fieldset>
      {canEdit && (
        <FormActions
          dirty={isDirty}
          saving={update.isPending}
          onDiscard={() => reset(toInput(shop))}
        />
      )}
    </form>
  );
}
