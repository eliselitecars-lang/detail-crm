import { zodResolver } from '@hookform/resolvers/zod';
import { ExternalLink, Plus, Trash2 } from 'lucide-react';
import { Controller, useFieldArray, useForm, useWatch } from 'react-hook-form';
import { Link } from 'react-router';
import { z } from 'zod';
import {
  Button,
  buttonClasses,
  CopyField,
  FormField,
  IconButton,
  Input,
  MoneyInput,
  SectionCard,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { LapsedFeatureNotice } from '@/features/billing/components/LapsedNotice';
import { toAppError } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { zOptionalText } from '@/lib/validation';
import { FormActions } from '../components/FormActions';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  GIFT_CARD_LIMITS,
  useGiftCardSettings,
  useUpdateGiftCardSettings,
  type GiftCardSettings,
} from '../data/moneySettings';
import { useSettingsAccess } from '../useSettingsAccess';

const { maxOffers, minValueCents, maxValueCents, minExpiryMonths, maxExpiryMonths } =
  GIFT_CARD_LIMITS;

const centsField = z.number().int().nullable();

const giftCardSchema = z
  .object({
    onlineEnabled: z.boolean(),
    offers: z.array(z.object({ value: centsField, price: centsField })).max(maxOffers),
    allowCustom: z.boolean(),
    minCustom: centsField,
    maxCustom: centsField,
    expires: z.boolean(),
    expiresMonths: z.string(),
    terms: zOptionalText(5000),
  })
  .superRefine((v, ctx) => {
    const range = `${formatCents(minValueCents)}–${formatCents(maxValueCents)}`;
    v.offers.forEach((offer, index) => {
      if (offer.value === null || offer.value < minValueCents || offer.value > maxValueCents) {
        ctx.addIssue({
          code: 'custom',
          path: ['offers', index, 'value'],
          message: `Card value must be ${range}.`,
        });
      }
      if (offer.price === null || offer.price <= 0) {
        ctx.addIssue({
          code: 'custom',
          path: ['offers', index, 'price'],
          message: 'Enter the price the buyer pays.',
        });
      } else if (offer.value !== null && offer.price > offer.value) {
        ctx.addIssue({
          code: 'custom',
          path: ['offers', index, 'price'],
          message: 'The price can’t be more than the card value.',
        });
      }
    });
    if (v.allowCustom) {
      if (v.minCustom === null || v.minCustom < minValueCents || v.minCustom > maxValueCents) {
        ctx.addIssue({ code: 'custom', path: ['minCustom'], message: `Use ${range}.` });
      }
      if (v.maxCustom === null || v.maxCustom < minValueCents || v.maxCustom > maxValueCents) {
        ctx.addIssue({ code: 'custom', path: ['maxCustom'], message: `Use ${range}.` });
      } else if (v.minCustom !== null && v.maxCustom < v.minCustom) {
        ctx.addIssue({
          code: 'custom',
          path: ['maxCustom'],
          message: 'The largest amount must be at least the smallest.',
        });
      }
    }
    if (v.onlineEnabled && v.offers.length === 0 && !v.allowCustom) {
      ctx.addIssue({
        code: 'custom',
        path: ['offers'],
        message: 'Add at least one card or allow custom amounts to sell online.',
      });
    }
    if (v.expires) {
      const months = Number(v.expiresMonths.trim());
      if (
        !/^\d+$/.test(v.expiresMonths.trim()) ||
        months < minExpiryMonths ||
        months > maxExpiryMonths
      ) {
        ctx.addIssue({
          code: 'custom',
          path: ['expiresMonths'],
          message: `Use ${minExpiryMonths} to ${maxExpiryMonths} months (at least 5 years).`,
        });
      }
    }
  });
type GiftCardInput = z.input<typeof giftCardSchema>;
type GiftCardValues = z.output<typeof giftCardSchema>;

function toInput(s: GiftCardSettings): GiftCardInput {
  return {
    onlineEnabled: s.online_enabled,
    offers: s.offers.map((o) => ({ value: o.value_cents, price: o.price_cents })),
    allowCustom: s.allow_custom_amount,
    minCustom: s.min_custom_cents,
    maxCustom: s.max_custom_cents,
    expires: s.expires_months !== null,
    expiresMonths: s.expires_months === null ? String(minExpiryMonths) : String(s.expires_months),
    terms: s.terms ?? '',
  };
}

export default function GiftCardSettingsPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const query = useGiftCardSettings();
  return (
    <SettingsSectionLayout section="gift-cards" readOnly={readOnly}>
      <LapsedFeatureNotice subject="Online gift card sales" />
      <QueryView query={query} label="gift card settings">
        {(settings) => (
          <GiftCardForm key={settings.updated_at} settings={settings} canEdit={canEdit} />
        )}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function GiftCardForm({ settings, canEdit }: { settings: GiftCardSettings; canEdit: boolean }) {
  const toast = useToast();
  const { shop, currency } = useShop();
  const update = useUpdateGiftCardSettings();
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors, isDirty },
  } = useForm<GiftCardInput, unknown, GiftCardValues>({
    resolver: zodResolver(giftCardSchema),
    defaultValues: toInput(settings),
  });
  const offers = useFieldArray({ control, name: 'offers' });
  const allowCustom = useWatch({ control, name: 'allowCustom' });
  const expires = useWatch({ control, name: 'expires' });
  const shopUrl = `${window.location.origin}/gift/${encodeURIComponent(shop.slug)}`;

  const onSubmit = handleSubmit(async (v) => {
    try {
      const saved = await update.mutateAsync({
        online_enabled: v.onlineEnabled,
        offers: v.offers.map((o) => ({ value_cents: o.value ?? 0, price_cents: o.price ?? 0 })),
        allow_custom_amount: v.allowCustom,
        ...(v.allowCustom
          ? {
              min_custom_cents: v.minCustom ?? minValueCents,
              max_custom_cents: v.maxCustom ?? maxValueCents,
            }
          : {}),
        expires_months: v.expires ? Number(v.expiresMonths.trim()) : null,
        terms: v.terms,
      });
      reset(toInput(saved));
      toast.success('Gift card settings saved');
    } catch (error) {
      toast.error(toAppError(error));
    }
  });

  const money = (
    name: `offers.${number}.value` | `offers.${number}.price` | 'minCustom' | 'maxCustom',
    label: string,
  ) => (
    <Controller
      control={control}
      name={name}
      render={({ field }) => (
        <MoneyInput
          aria-label={label}
          value={field.value}
          onChange={field.onChange}
          onBlur={field.onBlur}
          name={field.name}
        />
      )}
    />
  );

  return (
    <form onSubmit={(e) => void onSubmit(e)} noValidate className="flex flex-col gap-4">
      <SectionCard
        title="Your gift card page"
        description="Customers buy gift cards here and they’re emailed to the recipient with a code. Gift cards are paid for by card, so Stripe must be connected (Settings → Payments)."
      >
        <CopyField
          value={shopUrl}
          label="Gift card page link"
          copiedMessage="Gift card link copied"
          actions={
            <a
              href={shopUrl}
              target="_blank"
              rel="noreferrer"
              className={buttonClasses({ variant: 'ghost' })}
            >
              <ExternalLink className="size-4" aria-hidden="true" />
              Open
              <span className="sr-only"> gift card page in a new tab</span>
            </a>
          }
        />
        <p className="text-muted mt-2 text-xs">
          Staff can also issue gift cards and store credit on the{' '}
          <Link className="text-primary-ink underline" to="/app/gift-cards">
            Gift cards
          </Link>{' '}
          page. A gift card is a way to pay, not a discount: it’s used up like cash.
        </p>
      </SectionCard>

      <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-4">
        <legend className="sr-only">Gift card settings</legend>
        <SectionCard title="Online sales">
          <div className="flex flex-col gap-4">
            <Controller
              control={control}
              name="onlineEnabled"
              render={({ field }) => (
                <Switch
                  label="Sell gift cards online"
                  description="Off: the gift card page says gift cards aren’t available online."
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  disabled={!canEdit}
                />
              )}
            />
            <div className="flex flex-col gap-2">
              <p className="text-ink text-sm font-medium" id="gift-offers-label">
                Cards for sale
              </p>
              <p className="text-muted text-xs">
                Up to {maxOffers}. A price below the value sells the card at a discount (e.g. pay{' '}
                {formatCents(9000, { currency })}, get {formatCents(10000, { currency })}) — you set
                both.
              </p>
              {offers.fields.length === 0 ? (
                <p className="text-muted text-sm">No cards yet.</p>
              ) : (
                <ul className="flex flex-col gap-3" aria-labelledby="gift-offers-label">
                  {offers.fields.map((item, index) => (
                    <li key={item.id} className="flex flex-wrap items-start gap-3">
                      <FormField
                        label={`Card ${index + 1} value`}
                        error={errors.offers?.[index]?.value?.message}
                        className="w-40"
                      >
                        {money(`offers.${index}.value`, `Card ${index + 1} value`)}
                      </FormField>
                      <FormField
                        label="Buyer pays"
                        error={errors.offers?.[index]?.price?.message}
                        className="w-40"
                      >
                        {money(`offers.${index}.price`, `Card ${index + 1} price`)}
                      </FormField>
                      {canEdit && (
                        <IconButton
                          className="mt-6"
                          label={`Remove card ${index + 1}`}
                          icon={<Trash2 />}
                          size="sm"
                          variant="danger"
                          onClick={() => offers.remove(index)}
                        />
                      )}
                    </li>
                  ))}
                </ul>
              )}
              {errors.offers?.message && (
                <p role="alert" className="text-danger-ink text-xs font-medium">
                  {errors.offers.message}
                </p>
              )}
              {canEdit && offers.fields.length < maxOffers && (
                <div>
                  <Button
                    variant="secondary"
                    size="sm"
                    leadingIcon={<Plus className="size-4" aria-hidden="true" />}
                    onClick={() => offers.append({ value: null, price: null })}
                  >
                    Add a card
                  </Button>
                </div>
              )}
            </div>
            <Controller
              control={control}
              name="allowCustom"
              render={({ field }) => (
                <Switch
                  label="Let buyers choose the amount"
                  description="They pay exactly the amount they choose."
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  disabled={!canEdit}
                />
              )}
            />
            {allowCustom && (
              <div className="grid gap-4 sm:grid-cols-2">
                <FormField label="Smallest amount" error={errors.minCustom?.message}>
                  {money('minCustom', 'Smallest amount')}
                </FormField>
                <FormField label="Largest amount" error={errors.maxCustom?.message}>
                  {money('maxCustom', 'Largest amount')}
                </FormField>
              </div>
            )}
          </div>
        </SectionCard>

        <SectionCard title="Expiry & terms">
          <div className="flex flex-col gap-4">
            <Controller
              control={control}
              name="expires"
              render={({ field }) => (
                <Switch
                  label="Gift cards expire"
                  description="US law requires at least 5 years from the day a card is issued, and some states don’t allow expiry at all — check your state’s rules before turning this on."
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  disabled={!canEdit}
                />
              )}
            />
            {expires && (
              <FormField
                label="Expire after (months)"
                error={errors.expiresMonths?.message}
                help={`${minExpiryMonths}–${maxExpiryMonths} months after issue. Applies to cards issued from now on.`}
                className="max-w-xs"
              >
                <Input inputMode="numeric" {...register('expiresMonths')} />
              </FormField>
            )}
            <FormField
              label="Terms"
              error={errors.terms?.message}
              help="Shown to buyers on the gift card page."
            >
              <Textarea rows={3} maxLength={5000} {...register('terms')} />
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
