import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import {
  Button,
  Dialog,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  RadioGroup,
  Textarea,
  useToast,
} from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { formatPhone } from '@/lib/phone';
import { shopKey } from '@/lib/queryKeys';
import { useShop } from '@/features/shop/shopContext';
import {
  docTemplateVars,
  renderTemplate,
  useDocDefaults,
  useDocTemplate,
  useSendCustomerMessage,
  type DocTemplateKey,
  type MessageChannel,
  type PickerCustomer,
} from './api';

export type SendChoice = MessageChannel | 'none';

export interface SendDocumentDialogProps {
  open: boolean;
  onClose: () => void;
  kind: 'quote' | 'invoice';
  /** e.g. "Quote #1004" */
  documentLabel: string;
  customer: PickerCustomer;
  link: string;
  /** Invoice amounts from the server (template {{amount}} / {{balance}}). */
  amountCents?: number;
  balanceCents?: number;
  jobId?: string | null;
  /** mark_quote_sent / mark_invoice_sent */
  onMarkSent: () => Promise<unknown>;
  /** Resending an already-sent document. */
  resend?: boolean;
}

function channelBlock(customer: PickerCustomer, channel: MessageChannel): string | null {
  if (channel === 'sms') {
    if (!customer.phone) return 'No mobile number on file.';
    if (customer.sms_opted_out_at) return 'This customer opted out of texts.';
    return null;
  }
  if (!customer.email) return 'No email address on file.';
  if (customer.email_opted_out_at) return 'This customer unsubscribed from email.';
  return null;
}

/**
 * Marks the document sent and (optionally) texts/emails the customer the
 * shop's quote_sent / invoice_sent template with the client link.
 */
export function SendDocumentDialog(props: SendDocumentDialogProps) {
  return (
    <Dialog
      open={props.open}
      onClose={props.onClose}
      title={`${props.resend ? 'Resend' : 'Send'} ${props.documentLabel.toLowerCase()}`}
      description="The customer gets a link to view it online."
      size="lg"
    >
      {props.open && <SendDocumentForm {...props} />}
    </Dialog>
  );
}

function SendDocumentForm({
  onClose,
  kind,
  documentLabel,
  customer,
  link,
  amountCents,
  balanceCents,
  jobId,
  onMarkSent,
}: SendDocumentDialogProps) {
  const toast = useToast();
  const { shop, shopId, currency } = useShop();
  const smsBlock = channelBlock(customer, 'sms');
  const emailBlock = channelBlock(customer, 'email');
  const [choice, setChoice] = useState<SendChoice>(
    smsBlock === null ? 'sms' : emailBlock === null ? 'email' : 'none',
  );
  const channel: MessageChannel = choice === 'email' ? 'email' : 'sms';
  const templateKey: DocTemplateKey = kind === 'quote' ? 'quote_sent' : 'invoice_sent';
  const defaults = useDocDefaults();
  const template = useDocTemplate(templateKey, channel, choice !== 'none');

  const vars = docTemplateVars(templateKey, {
    customer,
    shopName: defaults.data?.name ?? shop.name,
    shopPhone: defaults.data?.phone ?? null,
    link,
    currency,
    ...(amountCents !== undefined ? { amountCents } : {}),
    ...(balanceCents !== undefined ? { balanceCents } : {}),
  });

  const rendered = useQuery({
    queryKey: shopKey(shopId, 'settings', 'money-template-render', templateKey, channel, vars),
    enabled: choice !== 'none' && template.isSuccess && defaults.isSuccess,
    queryFn: async () => {
      const tpl = template.data;
      if (!tpl) return { body: link, subject: `${documentLabel} from ${shop.name}` };
      const [body, subject] = await Promise.all([
        renderTemplate(tpl.body, vars),
        tpl.subject ? renderTemplate(tpl.subject, vars) : Promise.resolve(''),
      ]);
      return { body, subject: subject || `${documentLabel} from ${shop.name}` };
    },
  });

  const [edits, setEdits] = useState<{ body: string; subject: string } | null>(null);
  const [renderedFor, setRenderedFor] = useState<unknown>(null);
  if (rendered.data && renderedFor !== rendered.data) {
    setRenderedFor(rendered.data);
    setEdits({ ...rendered.data });
  }

  const send = useSendCustomerMessage();
  const [busy, setBusy] = useState(false);

  const submit = async () => {
    setBusy(true);
    try {
      await onMarkSent();
    } catch (error) {
      toast.error(error);
      setBusy(false);
      return;
    }
    if (choice === 'none' || !edits) {
      toast.success(`${documentLabel} marked as sent`);
      setBusy(false);
      onClose();
      return;
    }
    try {
      const result = await send.mutateAsync({
        customerId: customer.id,
        channel,
        body: edits.body,
        subject: edits.subject,
        jobId: jobId ?? null,
      });
      if (result.status === 'failed') {
        toast.show({
          tone: 'error',
          title: `${documentLabel} marked as sent, but the message failed`,
          description: result.error ?? 'Copy the link and share it another way.',
        });
      } else {
        toast.success(`${documentLabel} sent by ${channel === 'sms' ? 'text' : 'email'}`);
      }
      onClose();
    } catch (error) {
      toast.show({
        tone: 'error',
        title: `${documentLabel} marked as sent, but the message wasn’t sent`,
        description: errorMessage(error),
      });
      onClose();
    } finally {
      setBusy(false);
    }
  };

  const bodyTooLong = channel === 'sms' && (edits?.body.length ?? 0) > 1600;
  const needsBody = choice !== 'none';
  const ready = !needsBody || (edits !== null && edits.body.trim() !== '' && !bodyTooLong);

  return (
    <div className="flex flex-col gap-4">
      <RadioGroup<SendChoice>
        label="How should the customer get it?"
        value={choice}
        onChange={(next) => {
          setChoice(next);
          setEdits(null);
          setRenderedFor(null);
        }}
        options={[
          {
            value: 'sms',
            label: 'Text message',
            description: smsBlock ?? (customer.phone ? formatPhone(customer.phone) : undefined),
            disabled: smsBlock !== null,
          },
          {
            value: 'email',
            label: 'Email',
            description: emailBlock ?? customer.email ?? undefined,
            disabled: emailBlock !== null,
          },
          {
            value: 'none',
            label: 'Don’t message — just mark as sent',
            description: 'Copy the link and share it yourself.',
          },
        ]}
      />

      {needsBody &&
        (template.isError || rendered.isError || defaults.isError ? (
          <ErrorState
            compact
            error={template.error ?? rendered.error ?? defaults.error}
            onRetry={() => {
              void template.refetch();
              void defaults.refetch();
              void rendered.refetch();
            }}
          />
        ) : edits === null ? (
          <LoadingState label="Preparing message…" />
        ) : (
          <div className="flex flex-col gap-3">
            {template.data && !template.data.enabled && (
              <p className="text-warning-ink text-sm">
                This message template is turned off in Settings. You can still send the text below.
              </p>
            )}
            {channel === 'email' && (
              <FormField label="Subject">
                <Input
                  value={edits.subject}
                  maxLength={500}
                  onChange={(event) => setEdits({ ...edits, subject: event.target.value })}
                />
              </FormField>
            )}
            <FormField
              label="Message"
              error={bodyTooLong ? 'Text messages are limited to 1,600 characters.' : undefined}
              help={channel === 'sms' ? `${edits.body.length} / 1600 characters` : undefined}
            >
              <Textarea
                rows={channel === 'sms' ? 4 : 8}
                value={edits.body}
                onChange={(event) => setEdits({ ...edits, body: event.target.value })}
              />
            </FormField>
          </div>
        ))}

      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={busy}>
          Cancel
        </Button>
        <Button onClick={() => void submit()} loading={busy} disabled={!ready}>
          {choice === 'none' ? 'Mark as sent' : `Send ${channel === 'sms' ? 'text' : 'email'}`}
        </Button>
      </div>
    </div>
  );
}
