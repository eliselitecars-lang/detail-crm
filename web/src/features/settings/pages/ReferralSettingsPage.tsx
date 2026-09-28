import { zodResolver } from '@hookform/resolvers/zod';
import { Controller, useForm, useWatch } from 'react-hook-form';
import { z } from 'zod';
import {
  FormField,
  Input,
  MoneyInput,
  RadioGroup,
  SectionCard,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { toAppError } from '@/lib/errors';
import { bpsToPercentInput, formatBps, formatCents, parsePercentToBps } from '@/lib/money';
import { zOptionalText } from '@/lib/validation';
import { FormActions } from '../components/FormActions';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  useReferralSettings,
  useUpdateReferralSettings,
  type ReferralSettings,
} from '../data/moneySettings';
import { useSettingsAccess } from '../useSettingsAccess';

const referralSchema = z
  .object({
    enabled: z.boolean(),
    kind: z.enum(['percent', 'fixed']),
    percent: z.string(),
    amountCents: z.number().int().nullable(),
    rewardCents: z.number().int().nullable(),
    terms: zOptionalText(2000),
  })
  .superRefine((v, ctx) => {
    if (v.kind === 'percent') {
      const bps = parsePercentToBps(v.percent);
      if (v.enabled && (bps === null || bps <= 0)) {
        ctx.addIssue({
          code: 'custom',
          path: ['percent'],
          message: 'Enter a percentage between 0.01 and 100.',
        });
      } else if (v.percent.trim() !== '' && bps === null) {
        ctx.addIssue({
          code: 'custom',
          path: ['percent'],
          message: 'Enter a percentage up to 100.',
        });
      }
    } else if (v.enabled && (v.amountCents === null || v.amountCents <= 0)) {
      ctx.addIssue({
        code: 'custom',
        path: ['amountCents'],
        message: 'Enter an amount greater than $0.',
      });
    }
    if (v.rewardCents !== null && v.rewardCents < 0) {
      ctx.addIssue({ code: 'custom', path: ['rewardCents'], message: 'Use $0 or more.' });
    }
  });
type ReferralInput = z.input<typeof referralSchema>;
type ReferralValues = z.output<typeof referralSchema>;

function toInput(s: ReferralSettings): ReferralInput {
  return {
    enabled: s.enabled,
    kind: s.referee_discount_kind,
    percent:
      s.referee_discount_kind === 'percent' && s.referee_discount_value > 0
        ? bpsToPercentInput(s.referee_discount_value)
        : '',
    amountCents:
      s.referee_discount_kind === 'fixed' && s.referee_discount_value > 0
        ? s.referee_discount_value
        : null,
    rewardCents: s.referrer_reward_cents > 0 ? s.referrer_reward_cents : null,
    terms: s.terms ?? '',
  };
}

export default function ReferralSettingsPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const query = useReferralSettings();
  return (
    <SettingsSectionLayout section="referrals" readOnly={readOnly}>
      <QueryView query={query} label="referral settings">
        {(settings) => (
          <ReferralForm key={settings.updated_at} settings={settings} canEdit={canEdit} />
        )}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function ReferralForm({ settings, canEdit }: { settings: ReferralSettings; canEdit: boolean }) {
  const toast = useToast();
  const { currency } = useShop();
  const update = useUpdateReferralSettings();
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors, isDirty },
  } = useForm<ReferralInput, unknown, ReferralValues>({
    resolver: zodResolver(referralSchema),
    defaultValues: toInput(settings),
  });
  const kind = useWatch({ control, name: 'kind' });
  const percent = useWatch({ control, name: 'percent' });
  const amount = useWatch({ control, name: 'amountCents' });
  const reward = useWatch({ control, name: 'rewardCents' });
  const bps = parsePercentToBps(percent);
  const discountText =
    kind === 'percent'
      ? bps && bps > 0
        ? `${formatBps(bps)} off`
        : 'a discount'
      : amount && amount > 0
        ? `${formatCents(amount, { currency })} off`
        : 'a discount';
  const rewardText =
    reward && reward > 0 ? `${formatCents(reward, { currency })} in store credit` : null;

  const onSubmit = handleSubmit(async (v) => {
    const value = v.kind === 'percent' ? (parsePercentToBps(v.percent) ?? 0) : (v.amountCents ?? 0);
    try {
      const saved = await update.mutateAsync({
        enabled: v.enabled,
        referee_discount_kind: v.kind,
        referee_discount_value: value,
        referrer_reward_cents: v.rewardCents ?? 0,
        terms: v.terms,
      });
      reset(toInput(saved));
      toast.success('Referral settings saved');
    } catch (error) {
      toast.error(toAppError(error));
    }
  });

  return (
    <form onSubmit={(e) => void onSubmit(e)} noValidate className="flex flex-col gap-4">
      <SectionCard
        title="How it works"
        description="Each customer gets a personal referral code and link (from their page in Customers)."
      >
        <ol className="text-muted list-decimal space-y-1 pl-5 text-sm">
          <li>A customer shares their link or code with a friend.</li>
          <li>The friend books as a new customer and gets {discountText} on their first job.</li>
          <li>
            When that first job is completed,{' '}
            {rewardText
              ? `the customer who referred them gets ${rewardText} and a message with the credit code.`
              : 'the customer who referred them is thanked (add a reward below to give them store credit).'}
          </li>
        </ol>
      </SectionCard>
      <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-4">
        <legend className="sr-only">Referral settings</legend>
        <SectionCard title="Programme">
          <div className="flex flex-col gap-4">
            <Controller
              control={control}
              name="enabled"
              render={({ field }) => (
                <Switch
                  label="Referral programme on"
                  description="Off: referral codes stop working for new bookings."
                  checked={field.value}
                  onCheckedChange={field.onChange}
                  disabled={!canEdit}
                />
              )}
            />
            <div className="grid gap-4 sm:grid-cols-2">
              <Controller
                control={control}
                name="kind"
                render={({ field }) => (
                  <RadioGroup
                    label="New customer’s discount"
                    value={field.value}
                    onChange={field.onChange}
                    options={[
                      { value: 'percent', label: 'Percent off' },
                      { value: 'fixed', label: 'Amount off' },
                    ]}
                    disabled={!canEdit}
                  />
                )}
              />
              {kind === 'percent' ? (
                <FormField label="Discount percent" error={errors.percent?.message}>
                  <Input inputMode="decimal" trailing="%" {...register('percent')} />
                </FormField>
              ) : (
                <FormField label="Discount amount" error={errors.amountCents?.message}>
                  <Controller
                    control={control}
                    name="amountCents"
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
              <FormField
                label="Reward for the referrer"
                error={errors.rewardCents?.message}
                help="Store credit they can use on their own invoices. Leave empty for none."
              >
                <Controller
                  control={control}
                  name="rewardCents"
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
            </div>
            <FormField
              label="Terms"
              error={errors.terms?.message}
              help="Optional, shown with the referral code."
            >
              <Textarea rows={3} maxLength={2000} {...register('terms')} />
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
