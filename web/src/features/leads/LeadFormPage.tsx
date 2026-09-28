import { CircleCheck, Send, SearchX } from 'lucide-react';
import { useRef, useState, type FormEvent, type ReactNode } from 'react';
import { useParams, useSearchParams } from 'react-router';
import { CustomFieldInputs } from '@/components/customFields';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Button,
  Card,
  CardBody,
  Checkbox,
  EmptyState,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  PhoneInput,
  Textarea,
} from '@/components/ui';
import type { CustomFieldDraft } from '@/lib/customFields';
import { errorMessage, toAppError } from '@/lib/errors';
import { EmbedFrame } from '@/features/booking/components/EmbedFrame';
import { isEmbedMode, requestEmbedScrollTop } from '@/features/booking/embed';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { isLinkToken, toBranding } from '@/features/public-docs/shared/schemas';
import { useLeadForm, useSubmitLead, type LeadForm } from './api';
import {
  buildLeadPayload,
  EMPTY_LEAD,
  leadAnswers,
  leadSubmitErrorBanner,
  validateLead,
  type LeadErrors,
  type LeadInput,
} from './model';

export default function LeadFormPage() {
  const { token } = useParams();
  const [params] = useSearchParams();
  const embed = isEmbedMode(params);
  if (!isLinkToken(token)) {
    return (
      <LeadFrame form={null} embed={embed}>
        <NotFound />
      </LeadFrame>
    );
  }
  return <LeadFormView token={token} embed={embed} />;
}

/** PublicLayout, or the chrome-less frame when embedded in a shop's website. */
function LeadFrame({
  form,
  embed,
  children,
}: {
  form: LeadForm | null;
  embed: boolean;
  children: ReactNode;
}) {
  if (embed) return <EmbedFrame brandColor={form?.shop.brand_color}>{children}</EmbedFrame>;
  return <PublicLayout shop={form ? toBranding(form.shop) : null}>{children}</PublicLayout>;
}

function NotFound() {
  return (
    <Card>
      <EmptyState
        icon={<SearchX aria-hidden="true" />}
        title="This form isn’t available"
        description="The link may be incomplete, or the shop has taken the form down. Contact the shop directly."
      />
    </Card>
  );
}

function LeadFormView({ token, embed }: { token: string; embed: boolean }) {
  const form = useLeadForm(token);
  if (form.isPending) {
    return (
      <LeadFrame form={null} embed={embed}>
        <Card>
          <LoadingState label="Loading the form…" />
        </Card>
      </LeadFrame>
    );
  }
  if (form.isError) {
    return (
      <LeadFrame form={null} embed={embed}>
        {toAppError(form.error).kind === 'not_found' ? (
          <NotFound />
        ) : (
          <Card>
            <ErrorState
              error={form.error}
              title="Couldn’t load the form"
              onRetry={() => void form.refetch()}
              retrying={form.isFetching}
            />
          </Card>
        )}
      </LeadFrame>
    );
  }
  return (
    <LeadFrame form={form.data} embed={embed}>
      <LeadFormBody token={token} form={form.data} embed={embed} />
    </LeadFrame>
  );
}

function LeadFormBody({ token, form, embed }: { token: string; form: LeadForm; embed: boolean }) {
  const submit = useSubmitLead(token);
  const [input, setInput] = useState<LeadInput>(EMPTY_LEAD);
  const [answers, setAnswers] = useState<CustomFieldDraft>({});
  const [errors, setErrors] = useState<LeadErrors>({});
  const [answerErrors, setAnswerErrors] = useState<Record<string, string>>({});
  const [submitted, setSubmitted] = useState(false);
  const [done, setDone] = useState<string | null>(null);
  const doneRef = useRef<HTMLHeadingElement>(null);
  const options = { askVehicle: form.form.ask_vehicle, askMessage: form.form.ask_message };

  const update = (patch: Partial<LeadInput>) => {
    const next = { ...input, ...patch };
    setInput(next);
    if (submitted) setErrors(validateLead(next, options));
  };
  const updateAnswers = (next: CustomFieldDraft) => {
    setAnswers(next);
    if (submitted) setAnswerErrors(leadAnswers(form.fields, next).errors);
  };

  const onSubmit = (event: FormEvent) => {
    event.preventDefault();
    setSubmitted(true);
    const found = validateLead(input, options);
    const checked = leadAnswers(form.fields, answers);
    setErrors(found);
    setAnswerErrors(checked.errors);
    if (Object.keys(found).length > 0 || Object.keys(checked.errors).length > 0) return;
    // Embedded, the frame is sized to its content and cannot scroll: the
    // embedding page brings its top (the thank-you / the error) into view.
    const scrollToTop = () => (embed ? requestEmbedScrollTop() : window.scrollTo({ top: 0 }));
    submit.mutate(buildLeadPayload(input, options, checked.answers), {
      onSuccess: (result) => {
        setDone(result.message);
        scrollToTop();
        requestAnimationFrame(() => doneRef.current?.focus());
      },
      onError: scrollToTop,
    });
  };

  if (done !== null) {
    return (
      <Card as="section" aria-labelledby="lead-done-title">
        <CardBody className="flex flex-col items-center gap-3 py-10 text-center">
          <span className="bg-success-soft text-success-ink flex size-12 items-center justify-center rounded-full">
            <CircleCheck className="size-6" aria-hidden="true" />
          </span>
          <h1
            id="lead-done-title"
            ref={doneRef}
            tabIndex={-1}
            className="text-ink text-xl font-semibold outline-none"
          >
            Thank you!
          </h1>
          <p className="text-muted max-w-md text-sm whitespace-pre-line">{done}</p>
        </CardBody>
      </Card>
    );
  }

  const title = form.form.headline ?? form.form.name;
  const submitError = submit.isError ? toAppError(submit.error) : null;
  const errorBanner = submitError ? leadSubmitErrorBanner(submitError) : null;

  return (
    <Card as="section" aria-labelledby="lead-title">
      <form noValidate onSubmit={onSubmit}>
        <div className="border-line border-b px-4 py-4 sm:px-5">
          <h1 id="lead-title" className="text-ink text-lg font-semibold sm:text-xl">
            {title}
          </h1>
          {form.form.intro && (
            <p className="text-muted mt-1 text-sm whitespace-pre-line">{form.form.intro}</p>
          )}
        </div>
        <CardBody className="relative flex flex-col gap-5">
          {errorBanner && (
            <Banner tone={errorBanner.tone} title={errorBanner.title}>
              {errorMessage(submit.error)}
            </Banner>
          )}
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <FormField label="First name" required error={errors.firstName}>
              <Input
                value={input.firstName}
                onChange={(e) => update({ firstName: e.target.value })}
                autoComplete="given-name"
                maxLength={100}
              />
            </FormField>
            <FormField label="Last name" error={errors.lastName}>
              <Input
                value={input.lastName}
                onChange={(e) => update({ lastName: e.target.value })}
                autoComplete="family-name"
                maxLength={100}
              />
            </FormField>
            <FormField label="Email" error={errors.email} help="Or leave a phone number.">
              <Input
                type="email"
                value={input.email}
                onChange={(e) => update({ email: e.target.value })}
                autoComplete="email"
                maxLength={320}
              />
            </FormField>
            <FormField label="Phone" error={errors.phone}>
              <PhoneInput value={input.phone} onChange={(phone) => update({ phone })} />
            </FormField>
          </div>

          {options.askVehicle && (
            <fieldset className="flex flex-col gap-3">
              <legend className="text-ink mb-1 text-sm font-semibold">Your vehicle</legend>
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-[7rem_1fr_1fr]">
                <FormField label="Year" error={errors.vehicleYear}>
                  <Input
                    inputMode="numeric"
                    value={input.vehicleYear}
                    onChange={(e) => update({ vehicleYear: e.target.value })}
                    maxLength={4}
                  />
                </FormField>
                <FormField label="Make" error={errors.vehicleMake}>
                  <Input
                    value={input.vehicleMake}
                    onChange={(e) => update({ vehicleMake: e.target.value })}
                    maxLength={60}
                  />
                </FormField>
                <FormField label="Model" error={errors.vehicleModel}>
                  <Input
                    value={input.vehicleModel}
                    onChange={(e) => update({ vehicleModel: e.target.value })}
                    maxLength={60}
                  />
                </FormField>
              </div>
            </fieldset>
          )}

          {form.fields.length > 0 && (
            <CustomFieldInputs
              fields={form.fields}
              value={answers}
              onChange={updateAnswers}
              errors={answerErrors}
              showRequired
              columns={2}
            />
          )}

          {options.askMessage && (
            <FormField label="Message" error={errors.message}>
              <Textarea
                rows={4}
                value={input.message}
                onChange={(e) => update({ message: e.target.value })}
                maxLength={5000}
              />
            </FormField>
          )}

          {/* Honeypot: invisible to people and assistive tech; bots fill it in. */}
          <div aria-hidden="true" className="absolute -left-[10000px] h-px w-px overflow-hidden">
            <label htmlFor="lead-website">Website</label>
            <input
              id="lead-website"
              type="text"
              name="website"
              tabIndex={-1}
              autoComplete="off"
              value={input.website}
              onChange={(e) => update({ website: e.target.value })}
            />
          </div>

          <div className="flex flex-col gap-2">
            <Checkbox
              checked={input.smsOptIn}
              onChange={(e) => update({ smsOptIn: e.target.checked })}
              label="Text me about my request"
              description="Reply STOP to opt out."
            />
            <Checkbox
              checked={input.emailOptIn}
              onChange={(e) => update({ emailOptIn: e.target.checked })}
              label="Email me news and offers"
            />
          </div>
        </CardBody>
        <div className="border-line flex justify-end border-t px-4 py-3 sm:px-5">
          <Button
            type="submit"
            size="lg"
            loading={submit.isPending}
            leadingIcon={<Send className="size-4" aria-hidden="true" />}
          >
            Send
          </Button>
        </div>
      </form>
    </Card>
  );
}
