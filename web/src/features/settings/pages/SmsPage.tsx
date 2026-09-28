import { zodResolver } from '@hookform/resolvers/zod';
import { Check, MessageSquareText, Search, ShieldCheck } from 'lucide-react';
import { useState } from 'react';
import {
  Controller,
  useForm,
  useWatch,
  type FieldErrors,
  type UseFormRegister,
} from 'react-hook-form';
import { z } from 'zod';
import {
  Badge,
  Button,
  Card,
  Checkbox,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  RadioGroup,
  SectionCard,
  Select,
  Textarea,
  useToast,
  type BadgeTone,
} from '@/components/ui';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import { toAppError } from '@/lib/errors';
import { formatPhone } from '@/lib/phone';
import { zEmail, zPhone, zRequiredText } from '@/lib/validation';
import { requestNonce, useShopSettings, useUpdateShop, type ShopSettings } from '../api';
import { FormActions } from '../components/FormActions';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  usePurchaseNumber,
  useProvisioningFlags,
  useReleaseNumber,
  useSearchNumbers,
  useSmsNumberStatus,
  useSubmitVerification,
  type A2pBusiness,
  type A2pCampaign,
  type AvailableNumber,
  type BusinessInfo,
  type NumberSearch,
  type ProvisioningFlags,
  type SmsNumberStatus,
  type VerificationStatus,
} from '../data/smsProvisioning';
import { normalizeUrl, smsSchema, type SmsInput, type SmsValues } from '../schemas';

/** Owner/admin only (route guard: shop.manageSmsNumber). */
export default function SmsPage() {
  const shopQuery = useShopSettings();
  const flags = useProvisioningFlags();
  const status = useSmsNumberStatus();
  return (
    <SettingsSectionLayout section="sms">
      <QueryView query={shopQuery} label="SMS settings">
        {(shop) =>
          flags.isPending ? (
            <Card>
              <LoadingState label="Checking text messaging…" />
            </Card>
          ) : flags.isError ? (
            // Not knowing is not "not available": the manual form would hide a
            // number the shop bought here (and invite clearing it).
            <Card>
              <ErrorState
                title="Couldn’t check your text messaging setup"
                error={flags.error}
                onRetry={() => void flags.refetch()}
                retrying={flags.isRefetching}
              />
            </Card>
          ) : flags.data.enabled ? (
            <QueryView query={status} label="your number">
              {(number) => <SelfServe shop={shop} flags={flags.data} number={number} />}
            </QueryView>
          ) : (
            <>
              <SupportConnects />
              <SmsForm key={shop.id} shop={shop} />
            </>
          )
        }
      </QueryView>
    </SettingsSectionLayout>
  );
}

function SupportConnects() {
  return (
    <p
      role="note"
      className="rounded-card border-line bg-surface-2 text-muted flex gap-2 border px-3 py-2 text-sm"
    >
      <ShieldCheck className="text-primary mt-0.5 size-4 shrink-0" aria-hidden="true" />
      Buying a number yourself isn’t available yet: self-serve numbers need the platform’s Twilio
      account to be an approved reseller (ISV) with toll-free verification access. Until then,
      platform support connects your number, and you choose it below.
    </p>
  );
}

// ---------------------------------------------------------------------------
// Manual number (support-provisioned)
// ---------------------------------------------------------------------------

function SmsForm({ shop }: { shop: ShopSettings }) {
  const toast = useToast();
  const update = useUpdateShop();
  const {
    register,
    handleSubmit,
    reset,
    setError,
    formState: { errors, isDirty },
  } = useForm<SmsInput, unknown, SmsValues>({
    resolver: zodResolver(smsSchema),
    defaultValues: { smsFromNumber: shop.sms_from_number ?? '' },
  });

  const onSubmit = handleSubmit(async ({ smsFromNumber }) => {
    try {
      const saved = await update.mutateAsync({ sms_from_number: smsFromNumber });
      reset({ smsFromNumber: saved.sms_from_number ?? '' });
      toast.success(smsFromNumber ? 'SMS number saved' : 'SMS number removed');
    } catch (error) {
      const appError = toAppError(error);
      if (appError.code === '23505') {
        setError('smsFromNumber', { message: 'Another shop already uses this number.' });
        return;
      }
      toast.error(appError);
    }
  });

  return (
    <form onSubmit={(e) => void onSubmit(e)} noValidate className="flex flex-col gap-4">
      <SectionCard
        title="Sending number"
        actions={
          shop.sms_from_number ? (
            <Badge tone="success" dot>
              Texts on
            </Badge>
          ) : (
            <Badge tone="warning" dot>
              Texts off
            </Badge>
          )
        }
      >
        <div className="flex flex-col gap-4">
          <div className="text-muted flex gap-3 text-sm">
            <MessageSquareText className="text-primary mt-0.5 size-5 shrink-0" aria-hidden="true" />
            <div className="flex flex-col gap-1.5">
              <p>
                Appointment texts, reminders and two-way messages are sent from this number, and
                customer replies to it arrive in your Messages inbox.
              </p>
              <p>
                It must be a number provisioned for your shop on the platform’s Twilio account — a
                personal or other carrier number won’t work. Ask platform support for a number if
                you don’t have one yet. Without a number, text messages are skipped and only emails
                are sent.
              </p>
            </div>
          </div>
          <FormField
            label="SMS from number"
            error={errors.smsFromNumber?.message}
            help={
              shop.sms_from_number
                ? `Currently ${formatPhone(shop.sms_from_number)}. Clear the field to stop sending texts.`
                : 'US numbers can be typed like (205) 555-0123; others need a leading + and country code.'
            }
            className="max-w-sm"
          >
            <Input
              type="tel"
              inputMode="tel"
              autoComplete="off"
              placeholder="+12055550123"
              {...register('smsFromNumber')}
            />
          </FormField>
        </div>
      </SectionCard>
      <FormActions
        dirty={isDirty}
        saving={update.isPending}
        onDiscard={() => reset({ smsFromNumber: shop.sms_from_number ?? '' })}
      />
    </form>
  );
}

// ---------------------------------------------------------------------------
// Self-serve (SMS_PROVISIONING_ENABLED)
// ---------------------------------------------------------------------------

const STEPS: readonly { status: VerificationStatus; label: string }[] = [
  { status: 'not_started', label: 'Number bought' },
  { status: 'pending', label: 'Verification sent' },
  { status: 'in_review', label: 'Carriers reviewing' },
  { status: 'approved', label: 'Approved' },
];

const STATUS_BADGES: Record<VerificationStatus, { label: string; tone: BadgeTone }> = {
  not_started: { label: 'Not verified', tone: 'warning' },
  pending: { label: 'Verification sent', tone: 'info' },
  in_review: { label: 'In review', tone: 'info' },
  approved: { label: 'Verified', tone: 'success' },
  rejected: { label: 'Rejected', tone: 'danger' },
};

function SelfServe({
  shop,
  flags,
  number,
}: {
  shop: ShopSettings;
  flags: ProvisioningFlags;
  number: SmsNumberStatus;
}) {
  if (!number.provisioned || !number.number) {
    return (
      <>
        {shop.sms_from_number && (
          <p role="note" className="text-muted text-sm">
            Texts are sent from {formatPhone(shop.sms_from_number)} (connected by support). Buying a
            number here replaces it.
          </p>
        )}
        <BuyNumber flags={flags} />
      </>
    );
  }
  return <NumberCard flags={flags} number={number} numberE164={number.number} />;
}

function NumberCard({
  flags,
  number,
  numberE164,
}: {
  flags: ProvisioningFlags;
  number: SmsNumberStatus;
  numberE164: string;
}) {
  const toast = useToast();
  const isOwner = useCan('shop.delete');
  const release = useReleaseNumber();
  const [verifying, setVerifying] = useState(false);
  const [confirmRelease, setConfirmRelease] = useState(false);
  const status = number.verification_status ?? 'not_started';
  const kind = number.kind ?? 'tollfree';
  const canVerify = kind === 'tollfree' || flags.isv_enabled;
  const reached = STEPS.findIndex((s) => s.status === status);

  return (
    <SectionCard
      title={formatPhone(numberE164)}
      description={kind === 'tollfree' ? 'Toll-free number' : 'Local number'}
      actions={
        <Badge tone={STATUS_BADGES[status].tone} dot>
          {STATUS_BADGES[status].label}
        </Badge>
      }
    >
      <div className="flex flex-col gap-4">
        <ol className="flex flex-wrap gap-x-6 gap-y-2" aria-label="Verification progress">
          {STEPS.map((step, index) => {
            const done = status !== 'rejected' && reached >= index;
            return (
              <li
                key={step.status}
                className={
                  done
                    ? 'text-ink flex items-center gap-1.5 text-sm'
                    : 'text-muted flex items-center gap-1.5 text-sm'
                }
                aria-current={step.status === status ? 'step' : undefined}
              >
                <span
                  className={
                    done
                      ? 'bg-success-soft text-success-ink flex size-5 items-center justify-center rounded-full'
                      : 'border-line flex size-5 items-center justify-center rounded-full border text-xs'
                  }
                  aria-hidden="true"
                >
                  {done ? <Check className="size-3.5" /> : index + 1}
                </span>
                {step.label}
                {done && <span className="sr-only"> (done)</span>}
              </li>
            );
          })}
        </ol>
        {status === 'rejected' && (
          <div
            role="alert"
            className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
          >
            <p className="font-medium">The carriers rejected the verification.</p>
            {number.rejection_reason && <p className="mt-1">{number.rejection_reason}</p>}
            <p className="mt-1">Fix the details and send it again.</p>
          </div>
        )}
        <p className="text-muted text-sm">
          {status === 'approved'
            ? 'Your number is verified. Texts are delivered normally.'
            : status === 'pending' || status === 'in_review'
              ? 'Review usually takes a few business days. Until it’s approved, carriers may block or delay texts.'
              : kind === 'tollfree'
                ? 'Toll-free numbers must be verified before carriers deliver texts reliably. Send your business details to start.'
                : flags.isv_enabled
                  ? 'Local numbers need a 10DLC brand and campaign registration before texts are delivered. Send your business details to start.'
                  : 'Local numbers need 10DLC registration, which isn’t available on this platform yet. Contact support.'}
        </p>
        <div className="flex flex-wrap gap-2">
          {canVerify && (status === 'not_started' || status === 'rejected') && (
            <Button onClick={() => setVerifying(true)}>
              {status === 'rejected' ? 'Fix and resend' : 'Verify the number'}
            </Button>
          )}
          {isOwner && (
            <Button variant="ghost" onClick={() => setConfirmRelease(true)}>
              Release number
            </Button>
          )}
        </div>
      </div>
      {verifying && (
        <VerificationDialog
          kind={kind}
          resubmit={status === 'rejected'}
          onClose={() => setVerifying(false)}
        />
      )}
      <ConfirmDialog
        open={confirmRelease}
        onClose={() => setConfirmRelease(false)}
        tone="danger"
        title={`Release ${formatPhone(numberE164)}?`}
        description="Texts stop right away and the number goes back to the carrier — you may not get it back. Customers who text it won’t reach you."
        confirmLabel="Release number"
        loading={release.isPending}
        onConfirm={async () => {
          try {
            await release.mutateAsync();
            toast.success('Number released');
            setConfirmRelease(false);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}

function BuyNumber({ flags }: { flags: ProvisioningFlags }) {
  const toast = useToast();
  const purchase = usePurchaseNumber();
  const [kind, setKind] = useState<'tollfree' | 'local'>('tollfree');
  const [areaCode, setAreaCode] = useState('');
  const [contains, setContains] = useState('');
  const [search, setSearch] = useState<NumberSearch | null>(null);
  const [choice, setChoice] = useState<AvailableNumber | null>(null);
  const [nonce, setNonce] = useState(requestNonce);
  const results = useSearchNumbers(search);
  const areaProblem = kind === 'local' && areaCode !== '' && !/^[2-9]\d{2}$/.test(areaCode);
  const containsProblem = contains !== '' && !/^[0-9A-Za-z*]{1,10}$/.test(contains);

  return (
    <SectionCard
      title="Get a texting number"
      description="Buy a number for your shop. Texts and replies go through it, and it stays yours while you use it."
    >
      <div className="flex flex-col gap-4">
        <RadioGroup
          label="Type of number"
          variant="cards"
          value={kind}
          onChange={(v) => {
            setKind(v);
            setSearch(null);
            setChoice(null);
          }}
          options={[
            {
              value: 'tollfree',
              label: 'Toll-free (8XX)',
              description: 'Needs a one-time toll-free verification (a few business days).',
            },
            {
              value: 'local',
              label: 'Local number',
              description: flags.isv_enabled
                ? 'Your area code. Needs 10DLC brand and campaign registration.'
                : 'Not available yet: local numbers need 10DLC registration, which this platform can’t do yet.',
              disabled: !flags.isv_enabled,
            },
          ]}
        />
        <form
          className="flex flex-wrap items-end gap-3"
          onSubmit={(event) => {
            event.preventDefault();
            if (areaProblem || containsProblem) return;
            setChoice(null);
            setSearch({
              kind,
              ...(kind === 'local' && areaCode ? { areaCode } : {}),
              ...(contains ? { contains } : {}),
            });
          }}
        >
          {kind === 'local' && (
            <FormField
              label="Area code"
              error={areaProblem ? 'Three digits, not starting with 0 or 1.' : undefined}
              className="w-32"
            >
              <Input
                inputMode="numeric"
                maxLength={3}
                value={areaCode}
                onChange={(e) => setAreaCode(e.target.value.trim())}
              />
            </FormField>
          )}
          <FormField
            label="Contains (optional)"
            error={containsProblem ? 'Up to 10 digits or letters.' : undefined}
            className="w-48"
          >
            <Input
              maxLength={10}
              value={contains}
              onChange={(e) => setContains(e.target.value.trim())}
            />
          </FormField>
          <Button
            type="submit"
            variant="secondary"
            leadingIcon={<Search className="size-4" aria-hidden="true" />}
            loading={results.isFetching}
          >
            Search numbers
          </Button>
        </form>
        {search &&
          (results.isPending ? (
            <LoadingState label="Searching numbers…" />
          ) : results.isError ? (
            <p role="alert" className="text-danger-ink text-sm">
              {toAppError(results.error).message}
            </p>
          ) : results.data.length === 0 ? (
            <EmptyState
              compact
              title="No numbers found"
              description="Try other digits or another area code."
            />
          ) : (
            <RadioGroup
              label="Available numbers"
              value={choice?.phone_e164 ?? null}
              onChange={(v) => setChoice(results.data.find((n) => n.phone_e164 === v) ?? null)}
              options={results.data.map((n) => ({
                value: n.phone_e164,
                label: formatPhone(n.phone_e164),
                description: [n.locality, n.region].filter(Boolean).join(', ') || undefined,
              }))}
            />
          ))}
        {choice && (
          <div className="flex flex-col gap-2">
            <p className="text-muted text-xs">
              Numbers and text messages have carrier and Twilio costs. Check with the platform
              operator how they’re billed to your shop before buying.
            </p>
            <div>
              <Button
                loading={purchase.isPending}
                onClick={() =>
                  purchase.mutate(
                    { phone: choice.phone_e164, nonce },
                    {
                      onSuccess: () => {
                        toast.success(`${formatPhone(choice.phone_e164)} is yours`);
                        setNonce(requestNonce());
                      },
                      onError: (error) => toast.error(error),
                    },
                  )
                }
              >
                Buy {formatPhone(choice.phone_e164)}
              </Button>
            </div>
          </div>
        )}
      </div>
    </SectionCard>
  );
}

// ---------------------------------------------------------------------------
// Verification forms (sms-provisioning schemas: tollfreeBusinessSchema, a2p*)
// ---------------------------------------------------------------------------

const USE_CASES = [
  { value: 'ACCOUNT_NOTIFICATIONS', label: 'Appointment and account notifications' },
  { value: 'CUSTOMER_CARE', label: 'Customer care (two-way conversations)' },
  { value: 'DELIVERY_NOTIFICATIONS', label: 'Service status updates' },
  { value: 'MARKETING', label: 'Promotions (only to customers who opted in)' },
] as const;

const OPT_IN_TYPES = [
  { value: 'WEB_FORM', label: 'Online booking or web form checkbox' },
  { value: 'VERBAL', label: 'Verbal (in person or by phone)' },
  { value: 'PAPER_FORM', label: 'Paper form' },
  { value: 'VIA_TEXT', label: 'Customer texts a keyword first' },
  { value: 'MOBILE_QR_CODE', label: 'QR code' },
];

const VOLUMES = ['10', '100', '1,000', '10,000', '100,000'] as const;
const COUNTRIES = ['US', 'CA'] as const;

const httpsUrl = (message: string) =>
  z
    .string()
    .trim()
    .transform(normalizeUrl)
    .refine((v) => isWebUrl(v) && v.length <= 500, message);

function isWebUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return (url.protocol === 'https:' || url.protocol === 'http:') && url.hostname !== '';
  } catch {
    return false;
  }
}

const longText = (label: string, min: number, max: number) =>
  z
    .string()
    .trim()
    .min(min, `${label}: write at least ${min} characters.`)
    .max(max, `${label}: use ${max} characters or fewer.`);

/** Address + business fields both verifications share. */
const addressFields = {
  legalName: zRequiredText('Legal business name', 200),
  website: httpsUrl('Enter your website, like https://example.com.'),
  addressLine1: zRequiredText('Street address', 200),
  addressLine2: z.string().trim().max(200),
  city: zRequiredText('City', 100),
  region: z.string().trim().min(2, 'Enter the state or province.').max(50),
  postalCode: z.string().trim().min(3, 'Enter the postal code.').max(12),
  country: z.enum(COUNTRIES),
};

function addressDefaults(s: ShopSettings | undefined, shopName: string) {
  const country: (typeof COUNTRIES)[number] = s?.country === 'CA' ? 'CA' : 'US';
  return {
    legalName: s?.name ?? shopName,
    website: s?.website ?? '',
    addressLine1: s?.address_line1 ?? '',
    addressLine2: s?.address_line2 ?? '',
    city: s?.city ?? '',
    region: s?.region ?? '',
    postalCode: s?.postal_code ?? '',
    country,
  };
}

function AddressInputs({
  register,
  errors,
}: {
  register: UseFormRegister<AddressInput>;
  errors: FieldErrors<AddressInput>;
}) {
  return (
    <>
      <FormField label="Legal business name" required error={errors.legalName?.message}>
        <Input {...register('legalName')} />
      </FormField>
      <FormField label="Website" required error={errors.website?.message}>
        <Input inputMode="url" {...register('website')} />
      </FormField>
      <FormField label="Street address" required error={errors.addressLine1?.message}>
        <Input autoComplete="address-line1" {...register('addressLine1')} />
      </FormField>
      <FormField label="Address line 2" error={errors.addressLine2?.message}>
        <Input autoComplete="address-line2" {...register('addressLine2')} />
      </FormField>
      <FormField label="City" required error={errors.city?.message}>
        <Input autoComplete="address-level2" {...register('city')} />
      </FormField>
      <FormField label="State / province" required error={errors.region?.message}>
        <Input autoComplete="address-level1" {...register('region')} />
      </FormField>
      <FormField label="Postal code" required error={errors.postalCode?.message}>
        <Input autoComplete="postal-code" {...register('postalCode')} />
      </FormField>
      <FormField label="Country" required error={errors.country?.message}>
        <Select
          options={[
            { value: 'US', label: 'United States' },
            { value: 'CA', label: 'Canada' },
          ]}
          {...register('country')}
        />
      </FormField>
    </>
  );
}

type AddressShape = z.ZodObject<typeof addressFields>;
type AddressInput = z.input<AddressShape>;

function addressPayload(v: z.output<AddressShape>) {
  return {
    legal_name: v.legalName,
    website: v.website,
    address_line1: v.addressLine1,
    ...(v.addressLine2 ? { address_line2: v.addressLine2 } : {}),
    city: v.city,
    region: v.region,
    postal_code: v.postalCode,
    country: v.country,
  };
}

function VerificationDialog({
  kind,
  resubmit,
  onClose,
}: {
  kind: 'tollfree' | 'local';
  resubmit: boolean;
  onClose: () => void;
}) {
  return kind === 'tollfree' ? (
    <TollFreeDialog resubmit={resubmit} onClose={onClose} />
  ) : (
    <TenDlcDialog onClose={onClose} />
  );
}

const tollfreeSchema = z.object({
  ...addressFields,
  contactFirstName: zRequiredText('First name', 100),
  contactLastName: zRequiredText('Last name', 100),
  contactEmail: zEmail,
  contactPhone: zPhone,
  useCases: z.array(z.string()).min(1, 'Choose at least one.').max(5),
  summary: longText('Description', 20, 1000),
  sample: longText('Sample message', 20, 1000),
  optInType: z.string().min(1, 'Choose how customers agree.'),
  optInUrl: httpsUrl('Enter a link, like https://example.com/book.'),
  volume: z.enum(VOLUMES),
  editReason: z.string().trim().max(500),
});
type TollfreeInput = z.input<typeof tollfreeSchema>;
type TollfreeValues = z.output<typeof tollfreeSchema>;

function TollFreeDialog({ resubmit, onClose }: { resubmit: boolean; onClose: () => void }) {
  const toast = useToast();
  const { shop } = useShop();
  const shopSettings = useShopSettings();
  const submit = useSubmitVerification();
  const s = shopSettings.data;
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<TollfreeInput, unknown, TollfreeValues>({
    resolver: zodResolver(tollfreeSchema),
    defaultValues: {
      ...addressDefaults(s, shop.name),
      contactFirstName: '',
      contactLastName: '',
      contactEmail: s?.email ?? '',
      contactPhone: s?.phone ? formatPhone(s.phone) : '',
      useCases: ['ACCOUNT_NOTIFICATIONS', 'CUSTOMER_CARE'],
      summary: '',
      sample: '',
      optInType: 'WEB_FORM',
      optInUrl: `${window.location.origin}/book/${shop.slug}`,
      volume: '1,000',
      editReason: '',
    },
  });

  const onSubmit = handleSubmit(async (v) => {
    const business: BusinessInfo = {
      ...addressPayload(v),
      contact_first_name: v.contactFirstName,
      contact_last_name: v.contactLastName,
      contact_email: v.contactEmail,
      contact_phone: v.contactPhone,
      use_case_categories: v.useCases,
      use_case_summary: v.summary,
      production_message_sample: v.sample,
      opt_in_type: v.optInType,
      opt_in_image_urls: [v.optInUrl],
      estimated_monthly_volume: v.volume,
    };
    try {
      await submit.mutateAsync({
        kind: 'tollfree',
        business,
        ...(resubmit && v.editReason ? { editReason: v.editReason } : {}),
      });
      toast.success('Verification sent', 'Owners and admins are notified when it changes.');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  });

  const formId = 'sms-verification-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!submit.isPending}
      size="xl"
      title="Toll-free verification"
      description="Carriers use these details to check that your texts are wanted. They’re sent to Twilio and the carriers only for this review."
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={submit.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={submit.isPending}>
            Send for review
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="grid gap-4 sm:grid-cols-2"
      >
        <AddressInputs
          register={register as unknown as UseFormRegister<AddressInput>}
          errors={errors}
        />
        <FormField label="Contact first name" required error={errors.contactFirstName?.message}>
          <Input autoComplete="given-name" {...register('contactFirstName')} />
        </FormField>
        <FormField label="Contact last name" required error={errors.contactLastName?.message}>
          <Input autoComplete="family-name" {...register('contactLastName')} />
        </FormField>
        <FormField label="Contact email" required error={errors.contactEmail?.message}>
          <Input type="email" autoComplete="email" {...register('contactEmail')} />
        </FormField>
        <FormField label="Contact phone" required error={errors.contactPhone?.message}>
          <Input type="tel" autoComplete="tel" {...register('contactPhone')} />
        </FormField>
        <Controller
          control={control}
          name="useCases"
          render={({ field }) => (
            <fieldset className="flex flex-col gap-2 sm:col-span-2">
              <legend className="text-ink mb-1 text-sm font-medium">What you text about</legend>
              {USE_CASES.map((u) => (
                <Checkbox
                  key={u.value}
                  label={u.label}
                  checked={field.value.includes(u.value)}
                  onChange={(e) =>
                    field.onChange(
                      e.target.checked
                        ? [...field.value, u.value]
                        : field.value.filter((v) => v !== u.value),
                    )
                  }
                />
              ))}
              {errors.useCases?.message && (
                <p role="alert" className="text-danger-ink text-xs font-medium">
                  {errors.useCases.message}
                </p>
              )}
            </fieldset>
          )}
        />
        <FormField
          label="Describe your texts"
          required
          error={errors.summary?.message}
          help="Who receives texts and why, e.g. appointment confirmations, reminders and job updates for customers who booked with you."
          className="sm:col-span-2"
        >
          <Textarea rows={3} {...register('summary')} />
        </FormField>
        <FormField
          label="Sample message"
          required
          error={errors.sample?.message}
          help="Paste a real text you send, including how to opt out (Reply STOP to opt out)."
          className="sm:col-span-2"
        >
          <Textarea rows={2} {...register('sample')} />
        </FormField>
        <FormField label="How customers agree to texts" required error={errors.optInType?.message}>
          <Select options={OPT_IN_TYPES} {...register('optInType')} />
        </FormField>
        <FormField
          label="Where they agree (link)"
          required
          error={errors.optInUrl?.message}
          help="A page or screenshot showing the opt-in, e.g. your booking page."
        >
          <Input inputMode="url" {...register('optInUrl')} />
        </FormField>
        <FormField label="Texts per month (estimate)" required error={errors.volume?.message}>
          <Select options={VOLUMES.map((v) => ({ value: v, label: v }))} {...register('volume')} />
        </FormField>
        {resubmit && (
          <FormField
            label="What you changed"
            error={errors.editReason?.message}
            help="Optional note for the reviewers, e.g. “Added the opt-in wording to our booking page”."
            className="sm:col-span-2"
          >
            <Input maxLength={500} {...register('editReason')} />
          </FormField>
        )}
      </form>
    </Dialog>
  );
}

const BUSINESS_TYPES = [
  'Sole Proprietorship',
  'Partnership',
  'Corporation',
  'Co-operative',
  'Limited Liability Corporation',
  'Non-profit Corporation',
] as const;

const INDUSTRIES = [
  { value: 'AUTOMOTIVE', label: 'Automotive' },
  { value: 'CONSUMER', label: 'Consumer services' },
  { value: 'PROFESSIONAL_SERVICES', label: 'Professional services' },
  { value: 'RETAIL', label: 'Retail' },
] as const;

const JOB_POSITIONS = ['Director', 'GM', 'VP', 'CEO', 'CFO', 'General Counsel', 'Other'] as const;

const CAMPAIGN_USE_CASES = [
  { value: 'MIXED', label: 'Mixed (notifications and customer care)' },
  { value: 'ACCOUNT_NOTIFICATION', label: 'Account notifications' },
  { value: 'CUSTOMER_CARE', label: 'Customer care' },
  { value: 'MARKETING', label: 'Marketing' },
  { value: 'LOW_VOLUME', label: 'Low volume (mixed)' },
] as const;

const tenDlcSchema = z
  .object({
    ...addressFields,
    businessType: z.enum(BUSINESS_TYPES),
    industry: z.enum(INDUSTRIES.map((i) => i.value) as [string, ...string[]]),
    registrationNumber: z.string().trim().min(2, 'Enter your EIN / business number.').max(40),
    companyType: z.enum(['private', 'public', 'non-profit', 'government']),
    stockExchange: z.string().trim().max(20),
    stockTicker: z.string().trim().max(10),
    email: zEmail,
    repFirstName: zRequiredText('First name', 100),
    repLastName: zRequiredText('Last name', 100),
    repEmail: zEmail,
    repPhone: zPhone,
    repTitle: zRequiredText('Title', 100),
    repPosition: z.enum(JOB_POSITIONS),
    useCase: z.enum(CAMPAIGN_USE_CASES.map((u) => u.value) as [string, ...string[]]),
    description: longText('Campaign description', 40, 2048),
    messageFlow: longText('How customers opt in', 40, 2048),
    sample1: longText('Sample message 1', 20, 1024),
    sample2: longText('Sample message 2', 20, 1024),
    hasLinks: z.boolean(),
    hasPhone: z.boolean(),
  })
  .superRefine((v, ctx) => {
    if (v.companyType === 'public' && (v.stockExchange === '' || v.stockTicker === '')) {
      ctx.addIssue({
        code: 'custom',
        path: ['stockTicker'],
        message: 'Public companies need their stock exchange and ticker.',
      });
    }
  });
type TenDlcInput = z.input<typeof tenDlcSchema>;
type TenDlcValues = z.output<typeof tenDlcSchema>;

function TenDlcDialog({ onClose }: { onClose: () => void }) {
  const toast = useToast();
  const { shop } = useShop();
  const shopSettings = useShopSettings();
  const submit = useSubmitVerification();
  const s = shopSettings.data;
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<TenDlcInput, unknown, TenDlcValues>({
    resolver: zodResolver(tenDlcSchema),
    defaultValues: {
      ...addressDefaults(s, shop.name),
      businessType: 'Limited Liability Corporation',
      industry: 'AUTOMOTIVE',
      registrationNumber: '',
      companyType: 'private',
      stockExchange: '',
      stockTicker: '',
      email: s?.email ?? '',
      repFirstName: '',
      repLastName: '',
      repEmail: s?.email ?? '',
      repPhone: s?.phone ? formatPhone(s.phone) : '',
      repTitle: '',
      repPosition: 'Other',
      useCase: 'MIXED',
      description: '',
      messageFlow: '',
      sample1: '',
      sample2: '',
      hasLinks: true,
      hasPhone: true,
    },
  });
  const companyType = useWatch({ control, name: 'companyType' });

  const onSubmit = handleSubmit(async (v) => {
    const business: A2pBusiness = {
      ...addressPayload(v),
      business_type: v.businessType,
      industry: v.industry,
      registration_identifier: v.country === 'CA' ? 'CBN' : 'EIN',
      registration_number: v.registrationNumber,
      regions_of_operation: ['USA_AND_CANADA'],
      company_type: v.companyType,
      ...(v.companyType === 'public'
        ? { stock_exchange: v.stockExchange, stock_ticker: v.stockTicker }
        : {}),
      email: v.email,
      representative: {
        first_name: v.repFirstName,
        last_name: v.repLastName,
        email: v.repEmail,
        phone: v.repPhone,
        business_title: v.repTitle,
        job_position: v.repPosition,
      },
    };
    const campaign: A2pCampaign = {
      use_case: v.useCase,
      description: v.description,
      message_flow: v.messageFlow,
      message_samples: [v.sample1, v.sample2],
      has_embedded_links: v.hasLinks,
      has_embedded_phone: v.hasPhone,
    };
    try {
      await submit.mutateAsync({ kind: 'local', business, campaign });
      toast.success('Registration sent', 'Owners and admins are notified when it changes.');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  });

  const formId = 'sms-10dlc-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!submit.isPending}
      size="xl"
      title="10DLC registration"
      description="US carriers require a registered brand and campaign for texts from local numbers. These details go to Twilio and The Campaign Registry only for this review."
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={submit.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={submit.isPending}>
            Send for review
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="grid gap-4 sm:grid-cols-2"
      >
        <AddressInputs
          register={register as unknown as UseFormRegister<AddressInput>}
          errors={errors}
        />
        <FormField label="Business type" required error={errors.businessType?.message}>
          <Select
            options={BUSINESS_TYPES.map((t) => ({ value: t, label: t }))}
            {...register('businessType')}
          />
        </FormField>
        <FormField label="Industry" required error={errors.industry?.message}>
          <Select options={[...INDUSTRIES]} {...register('industry')} />
        </FormField>
        <FormField
          label="EIN (US) or business number (Canada)"
          required
          error={errors.registrationNumber?.message}
        >
          <Input autoComplete="off" {...register('registrationNumber')} />
        </FormField>
        <FormField label="Company type" required error={errors.companyType?.message}>
          <Select
            options={[
              { value: 'private', label: 'Private' },
              { value: 'public', label: 'Public (listed)' },
              { value: 'non-profit', label: 'Non-profit' },
              { value: 'government', label: 'Government' },
            ]}
            {...register('companyType')}
          />
        </FormField>
        {companyType === 'public' && (
          <>
            <FormField label="Stock exchange" error={errors.stockExchange?.message}>
              <Input {...register('stockExchange')} />
            </FormField>
            <FormField label="Stock ticker" error={errors.stockTicker?.message}>
              <Input {...register('stockTicker')} />
            </FormField>
          </>
        )}
        <FormField
          label="Email for review updates"
          required
          error={errors.email?.message}
          className="sm:col-span-2"
        >
          <Input type="email" autoComplete="email" {...register('email')} />
        </FormField>
        <FormField label="Representative first name" required error={errors.repFirstName?.message}>
          <Input autoComplete="given-name" {...register('repFirstName')} />
        </FormField>
        <FormField label="Representative last name" required error={errors.repLastName?.message}>
          <Input autoComplete="family-name" {...register('repLastName')} />
        </FormField>
        <FormField label="Representative email" required error={errors.repEmail?.message}>
          <Input type="email" {...register('repEmail')} />
        </FormField>
        <FormField label="Representative phone" required error={errors.repPhone?.message}>
          <Input type="tel" {...register('repPhone')} />
        </FormField>
        <FormField label="Representative title" required error={errors.repTitle?.message}>
          <Input {...register('repTitle')} />
        </FormField>
        <FormField label="Position" required error={errors.repPosition?.message}>
          <Select
            options={JOB_POSITIONS.map((p) => ({ value: p, label: p }))}
            {...register('repPosition')}
          />
        </FormField>
        <FormField label="Campaign type" required error={errors.useCase?.message}>
          <Select options={[...CAMPAIGN_USE_CASES]} {...register('useCase')} />
        </FormField>
        <FormField
          label="Campaign description"
          required
          error={errors.description?.message}
          help="What you text customers about and why (at least 40 characters)."
          className="sm:col-span-2"
        >
          <Textarea rows={3} {...register('description')} />
        </FormField>
        <FormField
          label="How customers opt in"
          required
          error={errors.messageFlow?.message}
          help="Where and how customers agree to texts, e.g. the consent checkbox on your booking page (at least 40 characters)."
          className="sm:col-span-2"
        >
          <Textarea rows={3} {...register('messageFlow')} />
        </FormField>
        <FormField
          label="Sample message 1"
          required
          error={errors.sample1?.message}
          className="sm:col-span-2"
        >
          <Textarea rows={2} {...register('sample1')} />
        </FormField>
        <FormField
          label="Sample message 2"
          required
          error={errors.sample2?.message}
          className="sm:col-span-2"
        >
          <Textarea rows={2} {...register('sample2')} />
        </FormField>
        <div className="flex flex-col gap-2 sm:col-span-2">
          <Controller
            control={control}
            name="hasLinks"
            render={({ field }) => (
              <Checkbox
                label="Messages contain links"
                checked={field.value}
                onChange={(e) => field.onChange(e.target.checked)}
              />
            )}
          />
          <Controller
            control={control}
            name="hasPhone"
            render={({ field }) => (
              <Checkbox
                label="Messages contain phone numbers"
                checked={field.value}
                onChange={(e) => field.onChange(e.target.checked)}
              />
            )}
          />
        </div>
      </form>
    </Dialog>
  );
}
