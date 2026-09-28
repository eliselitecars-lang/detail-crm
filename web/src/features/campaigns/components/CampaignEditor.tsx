import { zodResolver } from '@hookform/resolvers/zod';
import { Rocket, Save, Trash2 } from 'lucide-react';
import { useRef, useState } from 'react';
import { useForm, useWatch } from 'react-hook-form';
import { useNavigate } from 'react-router';
import type { z } from 'zod';
import {
  Button,
  ConfirmDialog,
  DateInput,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  RadioGroup,
  SectionCard,
  Textarea,
  TimeInput,
  useToast,
} from '@/components/ui';
import { formatDateTime, shopLocalToUtcIso, utcToShopLocal } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { BillingErrorLink } from '@/features/billing/BillingErrorLink';
import { useShop } from '@/features/shop/shopContext';
import { useDebouncedValue } from '@/lib/useDebouncedValue';
import {
  useAudiencePreview,
  useCampaignPreview,
  useDeleteCampaign,
  useLaunchCampaign,
  useSaveCampaign,
  type Campaign,
  type CampaignDraftInput,
} from '../api';
import {
  audienceFromForm,
  audienceRangeError,
  audienceToForm,
  audienceToJson,
  CAMPAIGN_PLACEHOLDERS,
  campaignFormSchema,
  EMAIL_BODY_MAX,
  EMPTY_AUDIENCE_FORM,
  hasPlaceholders,
  SMS_BODY_MAX,
  type AudienceForm,
  type CampaignChannel,
  type CampaignPreview,
} from '../model';
import { AudienceBuilder } from './AudienceBuilder';

type FormInput = z.input<typeof campaignFormSchema>;
type FormOutput = z.output<typeof campaignFormSchema>;

export interface CampaignEditorProps {
  /** A draft to edit; omit to create a new campaign. */
  campaign?: Campaign;
}

/** Create / edit a draft campaign, then launch it (with confirmation). */
export function CampaignEditor({ campaign }: CampaignEditorProps) {
  const { timezone } = useShop();
  const navigate = useNavigate();
  const toast = useToast();
  const save = useSaveCampaign();
  const launch = useLaunchCampaign();
  const remove = useDeleteCampaign();
  const [audience, setAudience] = useState<AudienceForm>(() =>
    campaign ? audienceToForm(campaign.audience) : { ...EMPTY_AUDIENCE_FORM },
  );
  const [submitError, setSubmitError] = useState<string | null>(null);
  /** The error behind submitError (the owner's billing link on a subscription refusal). */
  const [submitCause, setSubmitCause] = useState<unknown>(null);
  const fail = (error: unknown) => {
    setSubmitError(errorMessage(error));
    setSubmitCause(error);
  };
  const [confirmLaunch, setConfirmLaunch] = useState<{ id: string; sendAt: string | null } | null>(
    null,
  );
  const [confirmDelete, setConfirmDelete] = useState(false);
  // A new campaign is inserted on its first save; later saves update it.
  const [savedId, setSavedId] = useState<string | undefined>(campaign?.id);
  const bodyEl = useRef<HTMLTextAreaElement | null>(null);

  const scheduled = campaign?.scheduled_at ? utcToShopLocal(campaign.scheduled_at, timezone) : null;
  const {
    register,
    handleSubmit,
    control,
    setValue,
    getValues,
    formState: { errors, isSubmitting },
  } = useForm<FormInput, unknown, FormOutput>({
    resolver: zodResolver(campaignFormSchema),
    defaultValues: {
      name: campaign?.name ?? '',
      channel: campaign?.channel ?? 'sms',
      subject: campaign?.subject ?? '',
      body: campaign?.body ?? '',
      sendDate: scheduled?.date ?? '',
      sendTime: scheduled?.time ?? '',
    },
  });
  const channel = useWatch({ control, name: 'channel' });
  const body = useWatch({ control, name: 'body' }) ?? '';
  const subject = useWatch({ control, name: 'subject' }) ?? '';
  // The server renders the text as launch_campaign will (400 ms after typing stops).
  const previewInput = useDebouncedValue(
    { channel, body: body.trim(), subject: channel === 'email' ? subject.trim() || null : null },
    400,
  );
  const preview = useCampaignPreview(previewInput);
  const serverPreview = body.trim() !== '' && preview.data ? preview.data : null;
  const rangeError = audienceRangeError(audience);
  const audienceJson = audienceToJson(audienceFromForm(audience));
  const launchCount = useAudiencePreview(channel, audienceJson, confirmLaunch !== null);

  const toInput = (values: FormOutput): CampaignDraftInput => ({
    name: values.name,
    channel: values.channel,
    subject: values.channel === 'email' ? values.subject || null : null,
    body: values.body,
    audience: audienceJson,
    scheduled_at:
      values.sendDate && values.sendTime
        ? shopLocalToUtcIso(values.sendDate, values.sendTime, timezone)
        : null,
  });

  const persist = async (values: FormOutput) => {
    setSubmitError(null);
    setSubmitCause(null);
    const id = await save.mutateAsync({
      ...(savedId ? { id: savedId } : {}),
      values: toInput(values),
    });
    setSavedId(id);
    return id;
  };

  const onSave = handleSubmit(async (values) => {
    try {
      const id = await persist(values);
      toast.success('Draft saved');
      if (!campaign) await navigate(`/app/campaigns/${id}`, { replace: true });
    } catch (error) {
      fail(error);
    }
  });

  const onReviewLaunch = handleSubmit(async (values) => {
    if (rangeError) {
      setSubmitError(rangeError);
      setSubmitCause(null);
      return;
    }
    try {
      const id = await persist(values);
      setConfirmLaunch({ id, sendAt: toInput(values).scheduled_at });
    } catch (error) {
      fail(error);
    }
  });

  /** New campaigns live at /app/campaigns/:id once saved. */
  const leaveNewPage = async (id: string) => {
    if (!campaign) await navigate(`/app/campaigns/${id}`, { replace: true });
  };

  const doLaunch = async () => {
    if (!confirmLaunch) return;
    const { id } = confirmLaunch;
    try {
      const launched = await launch.mutateAsync(id);
      toast.success(
        `Campaign launched to ${launched.recipient_count.toLocaleString()} ${launched.recipient_count === 1 ? 'recipient' : 'recipients'}`,
      );
      setConfirmLaunch(null);
      await leaveNewPage(id);
    } catch (error) {
      setConfirmLaunch(null);
      fail(error);
    }
  };

  const closeLaunch = () => {
    const id = confirmLaunch?.id;
    setConfirmLaunch(null);
    if (id) void leaveNewPage(id);
  };

  const insertPlaceholder = (name: string) => {
    const token = `{{${name}}}`;
    const el = bodyEl.current;
    const current = getValues('body') ?? '';
    const start = el?.selectionStart ?? current.length;
    const end = el?.selectionEnd ?? current.length;
    setValue('body', current.slice(0, start) + token + current.slice(end), {
      shouldDirty: true,
      shouldValidate: errors.body !== undefined,
    });
    requestAnimationFrame(() => {
      el?.focus();
      el?.setSelectionRange(start + token.length, start + token.length);
    });
  };

  const lengthHelp = serverPreview
    ? previewLengthHelp(channel, serverPreview)
    : `${body.trim().length.toLocaleString()}/${(channel === 'sms' ? SMS_BODY_MAX : EMAIL_BODY_MAX).toLocaleString()} characters`;
  const placeholderNote = hasPlaceholders(body)
    ? ` Placeholders are filled in for each customer and make the ${
        channel === 'sms' ? 'text' : 'email'
      } longer; anything past the limit is cut off.`
    : '';
  const busy = isSubmitting || save.isPending || launch.isPending;
  const { ref: bodyRef, ...bodyField } = register('body');

  return (
    <form noValidate onSubmit={(event) => void onSave(event)} className="flex flex-col gap-5">
      {submitError && (
        <p
          role="alert"
          className="border-danger/30 bg-danger-soft text-danger-ink rounded-control border px-3 py-2 text-sm"
        >
          {submitError}
          <BillingErrorLink error={submitCause} />
        </p>
      )}

      <SectionCard title="Message">
        <div className="flex flex-col gap-4">
          <FormField
            label="Campaign name"
            error={errors.name?.message}
            required
            help="Only your team sees this."
          >
            <Input {...register('name')} maxLength={200} />
          </FormField>
          <RadioGroup<CampaignChannel>
            label="Channel"
            orientation="horizontal"
            value={channel}
            onChange={(next) => setValue('channel', next, { shouldDirty: true })}
            options={[
              { value: 'sms', label: 'Text message' },
              { value: 'email', label: 'Email' },
            ]}
          />
          {channel === 'email' && (
            <FormField label="Subject" error={errors.subject?.message} required>
              <Input {...register('subject')} maxLength={200} />
            </FormField>
          )}
          <FormField
            label="Message"
            required
            error={errors.body?.message}
            help={`${lengthHelp}${placeholderNote}`}
          >
            <Textarea
              rows={channel === 'sms' ? 5 : 10}
              {...bodyField}
              ref={(el) => {
                bodyRef(el);
                bodyEl.current = el;
              }}
            />
          </FormField>
          <CampaignPreviewPanel
            channel={channel}
            preview={serverPreview}
            loading={body.trim() !== '' && preview.isPending}
            error={preview.isError ? preview.error : null}
            onRetry={() => void preview.refetch()}
          />
          <div>
            <p className="text-muted mb-2 text-xs font-medium">Insert a placeholder</p>
            <ul className="flex flex-wrap gap-2" aria-label="Placeholders">
              {CAMPAIGN_PLACEHOLDERS.filter(
                (p) => channel === 'email' || p.name !== 'unsubscribe_link',
              ).map((p) => (
                <li key={p.name}>
                  <Button
                    type="button"
                    size="sm"
                    variant="secondary"
                    title={p.help}
                    aria-label={`Insert {{${p.name}}} — ${p.help}`}
                    onClick={() => insertPlaceholder(p.name)}
                  >
                    {`{{${p.name}}}`}
                  </Button>
                </li>
              ))}
            </ul>
          </div>
        </div>
      </SectionCard>

      <SectionCard
        title="Audience"
        description="Only customers who opted in to this channel and haven’t opted out receive it."
      >
        <AudienceBuilder
          value={audience}
          onChange={setAudience}
          channel={channel}
          disabled={busy}
        />
      </SectionCard>

      <SectionCard title="Send time" description={`Your shop’s time zone (${timezone}).`}>
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            label="Date"
            error={errors.sendDate?.message}
            help="Leave empty to send at launch."
          >
            <DateInput {...register('sendDate')} />
          </FormField>
          <FormField
            label="Time"
            error={errors.sendTime?.message}
            help="If this time has passed at launch, it sends right away."
          >
            <TimeInput {...register('sendTime')} />
          </FormField>
        </div>
      </SectionCard>

      <div className="flex flex-col-reverse gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div>
          {campaign && (
            <Button
              type="button"
              variant="ghost"
              leadingIcon={<Trash2 />}
              disabled={busy}
              onClick={() => setConfirmDelete(true)}
            >
              Delete draft
            </Button>
          )}
        </div>
        <div className="flex flex-col gap-2 sm:flex-row">
          <Button
            type="submit"
            variant="secondary"
            leadingIcon={<Save />}
            loading={save.isPending && !confirmLaunch}
            disabled={busy}
          >
            Save draft
          </Button>
          <Button
            type="button"
            leadingIcon={<Rocket />}
            disabled={busy}
            onClick={() => void onReviewLaunch()}
          >
            Review &amp; launch
          </Button>
        </div>
      </div>

      <ConfirmDialog
        open={confirmLaunch !== null}
        onClose={closeLaunch}
        onConfirm={doLaunch}
        loading={launch.isPending}
        title="Launch this campaign?"
        confirmLabel="Launch campaign"
        description="Messages are queued immediately and can’t be edited afterwards. You can cancel messages that haven’t been sent yet."
      >
        <ul className="text-ink flex flex-col gap-1 text-sm">
          <li>
            Channel: <strong>{channel === 'sms' ? 'Text message' : 'Email'}</strong>
          </li>
          <li>
            Recipients right now:{' '}
            <strong>
              {launchCount.isPending
                ? 'calculating…'
                : launchCount.error
                  ? 'unknown'
                  : launchCount.data?.toLocaleString()}
            </strong>
          </li>
          <li>
            Sends:{' '}
            <strong>
              {confirmLaunch?.sendAt
                ? formatDateTime(confirmLaunch.sendAt, timezone)
                : 'right away'}
            </strong>
          </li>
        </ul>
      </ConfirmDialog>

      {campaign && (
        <ConfirmDialog
          open={confirmDelete}
          onClose={() => setConfirmDelete(false)}
          tone="danger"
          loading={remove.isPending}
          title="Delete this draft?"
          description="The draft is removed permanently."
          confirmLabel="Delete draft"
          onConfirm={async () => {
            try {
              await remove.mutateAsync(campaign.id);
              setConfirmDelete(false);
              await navigate('/app/campaigns', { replace: true });
            } catch (error) {
              setConfirmDelete(false);
              fail(error);
            }
          }}
        />
      )}
    </form>
  );
}

function previewLengthHelp(channel: CampaignChannel, preview: CampaignPreview): string {
  const counts = `${preview.body_length.toLocaleString()}/${preview.max_body_length.toLocaleString()} characters`;
  if (channel === 'sms') {
    return preview.footer_added
      ? `${counts} · “Reply STOP to opt out.” is added automatically.`
      : counts;
  }
  return counts;
}

function CampaignPreviewPanel({
  channel,
  preview,
  loading,
  error,
  onRetry,
}: {
  channel: CampaignChannel;
  preview: CampaignPreview | null;
  loading: boolean;
  error: unknown;
  onRetry: () => void;
}) {
  if (error) {
    return (
      <ErrorState compact error={error} title="Couldn’t preview the message" onRetry={onRetry} />
    );
  }
  if (!preview) {
    return loading ? <LoadingState label="Rendering preview…" /> : null;
  }
  return (
    <section aria-label="Message preview" className="flex flex-col gap-2">
      <p className="text-muted text-xs font-medium tracking-wide uppercase">
        Preview{channel === 'email' ? ' (the unsubscribe link is added for each customer)' : ''}
      </p>
      <div className="bg-surface-2 rounded-control text-ink p-3 text-sm break-words whitespace-pre-wrap">
        {preview.subject && <p className="mb-1 font-semibold">{preview.subject}</p>}
        {preview.body}
      </div>
      {preview.truncated && (
        <p role="alert" className="text-warning-ink text-sm">
          This {channel === 'sms' ? 'text' : 'email'} is{' '}
          {(preview.body_length - preview.max_body_length).toLocaleString()} characters over the
          limit and will be cut off. Shorten it.
        </p>
      )}
      {channel === 'sms' && preview.footer_added && (
        <p className="text-muted text-xs">
          “Reply STOP to opt out.” is added because the text has no opt-out instruction.
        </p>
      )}
    </section>
  );
}
