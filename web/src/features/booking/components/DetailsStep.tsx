import { Tag, X } from 'lucide-react';
import { useState } from 'react';
import { CustomFieldInputs } from '@/components/customFields';
import { Button, Checkbox, FormField, Input, PhoneInput, Textarea } from '@/components/ui';
import type { CustomFieldDraft } from '@/lib/customFields';
import { errorMessage, sentenceCase } from '@/lib/errors';
import { formatCents } from '@/lib/money';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { usePricePreview, useValidateCoupon, type BookingQuestion, type ShopProfile } from '../api';
import {
  answersFor,
  COUPON_RE,
  isNanpCountry,
  locationFor,
  validateDetails,
  type DetailsInput,
  type FieldErrors,
} from '../model';
import { StepFrame } from './StepFrame';

export function DetailsStep({
  slug,
  profile,
  value,
  onChange,
  itemIds,
  categoryId,
  linkToken,
  questions,
  answers,
  onAnswersChange,
  couponPrefill,
  couponChecking = false,
  notice,
  questionsProblem = null,
  onBack,
  onContinue,
}: {
  slug: string;
  profile: ShopProfile;
  value: DetailsInput;
  onChange: (next: DetailsInput) => void;
  /** Services + add-ons (for the coupon preview). */
  itemIds: string[];
  /** null when the shop has no vehicle categories. */
  categoryId: string | null;
  linkToken: string | null;
  /** The shop's booking questions for the chosen location. */
  questions: readonly BookingQuestion[];
  answers: CustomFieldDraft;
  onAnswersChange: (next: CustomFieldDraft) => void;
  /**
   * A code from the link (?coupon=) the wizard has not applied yet: shown in
   * the input while it is checked, and kept there when it was rejected or
   * could not be checked.
   */
  couponPrefill: string;
  /** The wizard is checking couponPrefill right now. */
  couponChecking?: boolean;
  notice: string | null;
  /**
   * Set when the shop's booking questions failed to load: says so and offers
   * Try again, so a required question can still be shown and answered.
   */
  questionsProblem?: { retrying: boolean; onRetry: () => void } | null;
  onBack: () => void;
  onContinue: () => void;
}) {
  const [errors, setErrors] = useState<FieldErrors<keyof DetailsInput>>({});
  const [submitted, setSubmitted] = useState(false);
  const [codeInput, setCodeInput] = useState(value.couponCode || couponPrefill);
  const [codeError, setCodeError] = useState<string | null>(null);
  const [answerErrors, setAnswerErrors] = useState<Record<string, string>>({});
  const coupon = useValidateCoupon(slug);
  const currency = profile.currency;
  const businessType = profile.business_type;
  const location = locationFor(value, businessType);
  const mobile = location === 'mobile';

  const update = (patch: Partial<DetailsInput>) => {
    const next = { ...value, ...patch };
    onChange(next);
    if (submitted) setErrors(validateDetails(next, businessType, profile.country));
  };

  const updateAnswers = (next: CustomFieldDraft) => {
    onAnswersChange(next);
    if (submitted) setAnswerErrors(answersFor(questions, next).errors);
  };

  const applyCoupon = () => {
    const code = codeInput.trim();
    if (!COUPON_RE.test(code)) {
      setCodeError('Enter a valid code (letters, numbers, - and _).');
      return;
    }
    setCodeError(null);
    coupon.mutate(
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
            update({ couponCode: preview.code ?? code });
          } else {
            update({ couponCode: '' });
            setCodeError(
              [
                sentenceCase(preview.message ?? 'This coupon code is not valid'),
                preview.restrictions_text,
              ]
                .filter(Boolean)
                .join('. '),
            );
          }
        },
      },
    );
  };

  const removeCoupon = () => {
    coupon.reset();
    setCodeInput('');
    setCodeError(null);
    update({ couponCode: '' });
  };

  const next = () => {
    setSubmitted(true);
    const found = validateDetails(value, businessType, profile.country);
    const answerProblems = answersFor(questions, answers).errors;
    setErrors(found);
    setAnswerErrors(answerProblems);
    if (Object.keys(found).length === 0 && Object.keys(answerProblems).length === 0) onContinue();
  };

  // The applied code's discount (also when the wizard applied a code from the link).
  const applied = usePricePreview(
    slug,
    value.couponCode !== ''
      ? {
          serviceIds: itemIds,
          vehicleCategoryId: categoryId,
          code: value.couponCode,
          locationType: location,
          linkToken,
        }
      : null,
  );
  const preview =
    coupon.data?.valid && coupon.data.code?.toLowerCase() === value.couponCode.toLowerCase()
      ? coupon.data
      : applied.data?.valid
        ? applied.data
        : null;

  return (
    <StepFrame
      title="Your details"
      description="We’ll use these to confirm your appointment."
      onBack={onBack}
      onContinue={next}
    >
      {notice && <Banner tone="warning" title={notice} />}
      {questionsProblem && (
        <Banner
          tone="warning"
          title="We couldn’t load this shop’s booking questions."
          action={
            <Button
              size="sm"
              variant="secondary"
              loading={questionsProblem.retrying}
              onClick={questionsProblem.onRetry}
            >
              Try again
            </Button>
          }
        >
          If the shop asks anything before booking, the questions appear here once they load.
        </Banner>
      )}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <FormField label="First name" required error={errors.firstName}>
          <Input
            value={value.firstName}
            onChange={(event) => update({ firstName: event.target.value })}
            autoComplete="given-name"
            maxLength={100}
          />
        </FormField>
        <FormField label="Last name" error={errors.lastName}>
          <Input
            value={value.lastName}
            onChange={(event) => update({ lastName: event.target.value })}
            autoComplete="family-name"
            maxLength={100}
          />
        </FormField>
        <FormField label="Email" required error={errors.email}>
          <Input
            type="email"
            value={value.email}
            onChange={(event) => update({ email: event.target.value })}
            autoComplete="email"
            maxLength={254}
          />
        </FormField>
        <FormField
          label="Mobile phone"
          error={errors.phone}
          help={
            isNanpCountry(profile.country)
              ? undefined
              : 'Include your country code, starting with +.'
          }
        >
          <PhoneInput value={value.phone} onChange={(phone) => update({ phone })} />
        </FormField>
      </div>
      <div className="flex flex-col gap-2">
        <Checkbox
          checked={value.smsOptIn}
          onChange={(event) => update({ smsOptIn: event.target.checked })}
          label="Text me appointment updates"
          description="Reminders and “on my way” texts. Reply STOP to opt out."
        />
        <Checkbox
          checked={value.emailOptIn}
          onChange={(event) => update({ emailOptIn: event.target.checked })}
          label="Email me news and offers"
        />
      </div>

      {mobile && (
        <fieldset className="flex flex-col gap-4">
          <legend className="text-ink mb-1 text-sm font-semibold">Service address</legend>
          {profile.booking.service_area_limited && (
            <p className="text-muted -mt-2 text-xs">
              We serve a limited area — we’ll check your ZIP / postal code when you book.
            </p>
          )}
          <FormField label="Street address" required error={errors.addressLine1}>
            <Input
              value={value.addressLine1}
              onChange={(event) => update({ addressLine1: event.target.value })}
              autoComplete="address-line1"
              maxLength={200}
            />
          </FormField>
          <FormField label="Apt, suite, etc." error={errors.addressLine2}>
            <Input
              value={value.addressLine2}
              onChange={(event) => update({ addressLine2: event.target.value })}
              autoComplete="address-line2"
              maxLength={200}
            />
          </FormField>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <FormField label="City" required error={errors.city}>
              <Input
                value={value.city}
                onChange={(event) => update({ city: event.target.value })}
                autoComplete="address-level2"
                maxLength={100}
              />
            </FormField>
            <FormField label="State / region" error={errors.region}>
              <Input
                value={value.region}
                onChange={(event) => update({ region: event.target.value })}
                autoComplete="address-level1"
                maxLength={100}
              />
            </FormField>
            <FormField label="ZIP / postal code" required error={errors.postalCode}>
              <Input
                value={value.postalCode}
                onChange={(event) => update({ postalCode: event.target.value })}
                autoComplete="postal-code"
                maxLength={20}
              />
            </FormField>
          </div>
        </fieldset>
      )}

      {questions.length > 0 && (
        <fieldset className="flex flex-col gap-3">
          <legend className="text-ink mb-1 text-sm font-semibold">A few questions</legend>
          <CustomFieldInputs
            fields={questions}
            value={answers}
            onChange={updateAnswers}
            errors={answerErrors}
            showRequired
            columns={2}
          />
        </fieldset>
      )}

      <FormField
        label="Notes for the shop"
        error={errors.notes}
        help="Anything we should know — pet hair, stains, gate codes…"
      >
        <Textarea
          value={value.notes}
          onChange={(event) => update({ notes: event.target.value })}
          maxLength={2000}
          rows={3}
        />
      </FormField>

      <div className="flex flex-col gap-2">
        {value.couponCode !== '' ? (
          <div
            role="status"
            className="rounded-card border-success/30 bg-success-soft text-success-ink flex items-center gap-3 border px-3 py-2 text-sm"
          >
            <Tag className="size-4 shrink-0" aria-hidden="true" />
            <span className="min-w-0 flex-1">
              Code <strong>{value.couponCode}</strong> applied
              {preview && preview.discount_cents > 0
                ? ` — ${formatCents(preview.discount_cents, { currency })} off`
                : ''}
              {preview?.description ? ` (${preview.description})` : ''}
            </span>
            <Button
              variant="ghost"
              size="sm"
              onClick={removeCoupon}
              leadingIcon={<X className="size-4" aria-hidden="true" />}
            >
              Remove
            </Button>
          </div>
        ) : (
          <FormField
            label="Coupon code"
            error={codeError ?? (coupon.isError ? errorMessage(coupon.error) : null)}
          >
            <div className="flex gap-2">
              <Input
                value={codeInput}
                onChange={(event) => setCodeInput(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    event.preventDefault();
                    applyCoupon();
                  }
                }}
                maxLength={40}
                autoComplete="off"
                disabled={couponChecking}
                className="min-w-0 flex-1"
              />
              <Button
                variant="secondary"
                onClick={() => applyCoupon()}
                loading={coupon.isPending || couponChecking}
                disabled={codeInput.trim() === ''}
              >
                Apply
              </Button>
            </div>
          </FormField>
        )}
      </div>
    </StepFrame>
  );
}
