import { Send } from 'lucide-react';
import { useId, useState, type FormEvent, type KeyboardEvent } from 'react';
import {
  Button,
  FormField,
  Input,
  RadioGroup,
  Select,
  statusLabel,
  Textarea,
  type SelectOption,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { useCustomerJobs, useMessageTemplates, useSendMessage, useTemplatePreview } from '../api';
import {
  channelAvailability,
  EMAIL_MAX_LENGTH,
  JOB_TEMPLATE_KEYS,
  SMS_MAX_LENGTH,
  smsSegments,
  TEMPLATE_LABELS,
  type MessageChannel,
  type MessageTemplateKey,
  type ThreadCustomer,
} from '../model';

export interface ComposerProps {
  customer: ThreadCustomer;
  timeZone: string;
  /** Preferred channel (e.g. the thread's latest). */
  defaultChannel?: MessageChannel;
}

function pickChannel(customer: ThreadCustomer, preferred: MessageChannel | undefined) {
  const order: MessageChannel[] = preferred === 'email' ? ['email', 'sms'] : ['sms', 'email'];
  return order.find((c) => channelAvailability(customer, c).available) ?? order[0] ?? 'sms';
}

/** Compose a free-form or templated SMS/email; the server renders and sends it. */
export function Composer({ customer, timeZone, defaultChannel }: ComposerProps) {
  const [channel, setChannel] = useState<MessageChannel>(() =>
    pickChannel(customer, defaultChannel),
  );
  const [templateKey, setTemplateKey] = useState<MessageTemplateKey | ''>('');
  const [jobId, setJobId] = useState('');
  const [subject, setSubject] = useState('');
  const [body, setBody] = useState('');
  const [touched, setTouched] = useState(false);
  const hintId = useId();

  const send = useSendMessage();
  const templates = useMessageTemplates();
  const jobs = useCustomerJobs(templateKey ? customer.id : null);
  const preview = useTemplatePreview(jobId || null, templateKey || null, channel);

  const sms = channelAvailability(customer, 'sms');
  const email = channelAvailability(customer, 'email');
  const current = channel === 'sms' ? sms : email;

  const channelTemplates = (templates.data ?? []).filter((t) => t.channel === channel && t.enabled);
  const selectedTemplate = channelTemplates.find((t) => t.key === templateKey) ?? null;
  const templateOptions: SelectOption[] = [
    { value: '', label: 'No template — write a message' },
    ...channelTemplates.map((t) => ({ value: t.key, label: TEMPLATE_LABELS[t.key] })),
  ];
  const jobOptions: SelectOption[] = [
    { value: '', label: 'No job' },
    ...(jobs.data ?? []).map((j) => ({
      value: j.id,
      label: `Job #${j.number} · ${statusLabel('job', j.status)}${j.scheduled_start ? ` · ${formatDate(j.scheduled_start, timeZone)}` : ''}`,
    })),
  ];

  const max = channel === 'sms' ? SMS_MAX_LENGTH : EMAIL_MAX_LENGTH;
  const bodyError =
    !templateKey && touched && body.trim() === ''
      ? 'Write a message first.'
      : body.length > max
        ? `Keep it under ${max.toLocaleString()} characters.`
        : undefined;
  const subjectError = subject.length > 200 ? 'Keep the subject under 200 characters.' : undefined;
  const canSend =
    current.available &&
    !send.isPending &&
    (templateKey ? selectedTemplate !== null : body.trim() !== '' && body.length <= max) &&
    !subjectError;

  const changeChannel = (next: MessageChannel) => {
    setChannel(next);
    setTemplateKey('');
    send.reset();
  };

  const submit = (event?: FormEvent) => {
    event?.preventDefault();
    setTouched(true);
    if (!canSend) return;
    send.mutate(
      {
        customerId: customer.id,
        channel,
        jobId: jobId || null,
        content: templateKey
          ? { kind: 'template', templateKey }
          : { kind: 'text', subject: subject.trim() || null, body: body.trim() },
      },
      {
        onSuccess: () => {
          setBody('');
          setSubject('');
          setTemplateKey('');
          setJobId('');
          setTouched(false);
        },
      },
    );
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) submit();
  };

  return (
    <form
      onSubmit={submit}
      aria-label="Compose message"
      className="border-line bg-surface flex flex-col gap-3 border-t p-3 sm:p-4"
    >
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        <RadioGroup<MessageChannel>
          label="Send as"
          hideLabel
          orientation="horizontal"
          value={channel}
          onChange={changeChannel}
          options={[
            { value: 'sms', label: 'Text', disabled: !sms.available },
            { value: 'email', label: 'Email', disabled: !email.available },
          ]}
        />
        <FormField label="Template" hideLabel className="min-w-0 flex-1 sm:max-w-xs">
          <Select
            value={templateKey}
            options={templateOptions}
            disabled={!current.available || templates.isPending}
            onChange={(e) => {
              setTemplateKey(channelTemplates.find((t) => t.key === e.target.value)?.key ?? '');
              setJobId('');
              send.reset();
            }}
          />
        </FormField>
      </div>

      {!current.available && (
        <p className="text-warning-ink text-sm" role="status">
          {channel === 'sms' ? 'Texting' : 'Email'} is unavailable: {current.reason}
        </p>
      )}

      {templateKey && selectedTemplate ? (
        <div className="flex flex-col gap-2">
          <FormField
            label="Job for this message"
            help={
              JOB_TEMPLATE_KEYS.has(templateKey)
                ? 'Job details (date, vehicle, services, links) are filled in from this job.'
                : undefined
            }
          >
            <Select
              value={jobId}
              options={jobOptions}
              disabled={jobs.isPending}
              onChange={(e) => setJobId(e.target.value)}
            />
          </FormField>
          <div className="bg-surface-2 rounded-control p-3 text-sm" aria-live="polite">
            <p className="text-muted mb-1 text-xs font-medium tracking-wide uppercase">
              {jobId ? 'Preview' : 'Template wording'}
            </p>
            {jobId && preview.isPending ? (
              <p className="text-muted">Loading preview…</p>
            ) : jobId && preview.data?.body ? (
              <>
                {preview.data.subject && <p className="font-semibold">{preview.data.subject}</p>}
                <p className="whitespace-pre-wrap">{preview.data.body}</p>
              </>
            ) : (
              <>
                {selectedTemplate.subject && (
                  <p className="font-semibold">{selectedTemplate.subject}</p>
                )}
                <p className="whitespace-pre-wrap">{selectedTemplate.body}</p>
                {!jobId && JOB_TEMPLATE_KEYS.has(templateKey) && (
                  <p className="text-muted mt-2 text-xs">
                    Without a job, job placeholders such as {'{{job_date}}'} are left blank.
                  </p>
                )}
              </>
            )}
          </div>
        </div>
      ) : (
        <>
          {channel === 'email' && (
            <FormField
              label="Subject"
              error={subjectError}
              help="Optional — defaults to your shop name."
            >
              <Input
                value={subject}
                maxLength={200}
                disabled={!current.available}
                onChange={(e) => setSubject(e.target.value)}
              />
            </FormField>
          )}
          <FormField
            label="Message"
            hideLabel={channel === 'sms'}
            error={bodyError}
            help={
              <span id={hintId}>
                {channel === 'sms'
                  ? `${body.length}/${SMS_MAX_LENGTH} · ${smsSegments(body)} segment${smsSegments(body) === 1 ? '' : 's'}`
                  : `${body.length.toLocaleString()} characters`}{' '}
                · Ctrl/⌘ + Enter to send
              </span>
            }
          >
            <Textarea
              rows={3}
              value={body}
              disabled={!current.available}
              placeholder={channel === 'sms' ? 'Write a text…' : 'Write an email…'}
              onChange={(e) => setBody(e.target.value)}
              onKeyDown={onKeyDown}
            />
          </FormField>
        </>
      )}

      {send.error && (
        <p className="text-danger-ink text-sm" role="alert">
          {errorMessage(send.error)}
        </p>
      )}

      <div className="flex justify-end">
        <Button
          type="submit"
          leadingIcon={<Send />}
          loading={send.isPending}
          disabled={!current.available || (templateKey !== '' && selectedTemplate === null)}
        >
          {templateKey ? 'Send template' : channel === 'sms' ? 'Send text' : 'Send email'}
        </Button>
      </div>
    </form>
  );
}
