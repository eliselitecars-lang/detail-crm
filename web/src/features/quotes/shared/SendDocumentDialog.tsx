import { Copy } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router';
import { Button, Dialog, ErrorState, LoadingState, RadioGroup, useToast } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { formatPhone } from '@/lib/phone';
import { useCan } from '@/features/shop/useCan';
import {
  useDocumentPreview,
  useSendDocumentMessage,
  type DocumentKind,
  type MessageChannel,
  type PickerCustomer,
} from './api';
import { EdgeFunctionError } from './edge';
import { copyText, newRequestNonce } from './format';
import { BillingErrorLink } from '@/features/billing/BillingErrorLink';

export type SendChoice = MessageChannel | 'none';

export interface SendDocumentDialogProps {
  open: boolean;
  onClose: () => void;
  kind: DocumentKind;
  /** The quote / invoice id (the server renders its message from it). */
  documentId: string;
  /** e.g. "Quote #1004" */
  documentLabel: string;
  customer: PickerCustomer;
  /** The client link, for sharing it another way. */
  link: string;
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
 * shop's quote_sent / invoice_sent template. The server renders and sends
 * the message (preview_document_message for the preview, messaging.send with
 * quote_id / invoice_id for the send), so what staff see is what goes out.
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
  documentId,
  documentLabel,
  customer,
  link,
  onMarkSent,
}: SendDocumentDialogProps) {
  const toast = useToast();
  const canEditTemplates = useCan('settings.manage');
  const smsBlock = channelBlock(customer, 'sms');
  const emailBlock = channelBlock(customer, 'email');
  const [choice, setChoice] = useState<SendChoice>(
    smsBlock === null ? 'sms' : emailBlock === null ? 'email' : 'none',
  );
  const channel: MessageChannel = choice === 'email' ? 'email' : 'sms';
  const doc = { kind, id: documentId };
  const preview = useDocumentPreview(doc, channel, choice !== 'none');
  const send = useSendDocumentMessage();
  // One nonce per compose (the form remounts on every open): a retry after a
  // network error replays the same request and can never send twice.
  const [nonce] = useState(newRequestNonce);
  /** mark_*_sent succeeded in this dialog: a retry only re-sends the message. */
  const [markedSent, setMarkedSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<unknown>(null);

  const templateOff = choice !== 'none' && preview.data?.enabled === false;
  const failureReason = failure instanceof EdgeFunctionError ? failure.reason : null;
  const offerLink = templateOff || failureReason === 'template_disabled';

  const markSent = async (): Promise<boolean> => {
    if (markedSent) return true;
    try {
      await onMarkSent();
      setMarkedSent(true);
      return true;
    } catch (error) {
      toast.error(error);
      return false;
    }
  };

  const submit = async () => {
    setBusy(true);
    setFailure(null);
    try {
      if (!(await markSent())) return;
      if (choice === 'none') {
        toast.success(`${documentLabel} marked as sent`);
        onClose();
        return;
      }
      const result = await send.mutateAsync({ doc, channel, requestNonce: nonce });
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
      // Refused (422 with the server's reason) or not delivered: stay open so
      // staff can read why, retry with the same nonce, or share the link.
      setFailure(error);
    } finally {
      setBusy(false);
    }
  };

  const copy = async () => {
    if (await copyText(link)) toast.success('Link copied');
    else toast.error('Couldn’t copy the link', link);
  };

  const needsPreview = choice !== 'none';
  const ready = !needsPreview || (preview.isSuccess && preview.data.enabled);

  return (
    <div className="flex flex-col gap-4">
      <RadioGroup<SendChoice>
        label="How should the customer get it?"
        value={choice}
        onChange={(next) => {
          setChoice(next);
          setFailure(null);
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

      {needsPreview &&
        (preview.isPending ? (
          <LoadingState label="Preparing message…" />
        ) : preview.isError ? (
          <ErrorState compact error={preview.error} onRetry={() => void preview.refetch()} />
        ) : (
          <section aria-label="Message preview" className="flex flex-col gap-2">
            {templateOff ? (
              <p className="text-warning-ink text-sm">
                The {kind} message is turned off for {channel === 'sms' ? 'texts' : 'email'} in
                Settings, so nothing can be sent. Mark it as sent and share the link yourself.
              </p>
            ) : (
              <>
                {channel === 'email' && preview.data.subject && (
                  <p className="text-ink text-sm">
                    <span className="text-muted">Subject: </span>
                    {preview.data.subject}
                  </p>
                )}
                <div className="bg-surface-2 rounded-control text-ink p-3 text-sm break-words whitespace-pre-wrap">
                  {preview.data.body}
                </div>
                <p className="text-muted text-xs">
                  This is exactly what the customer receives.{' '}
                  {canEditTemplates ? (
                    <>
                      Change the wording in{' '}
                      <Link
                        to="/app/settings/templates"
                        className="text-primary-ink hover:underline"
                      >
                        message templates
                      </Link>
                      .
                    </>
                  ) : (
                    'An owner or admin can change the wording in Settings.'
                  )}
                </p>
              </>
            )}
          </section>
        ))}

      {failure !== null && (
        <div
          role="alert"
          className="bg-danger-soft text-danger-ink rounded-control px-3 py-2.5 text-sm"
        >
          <p className="font-medium">
            {markedSent
              ? `${documentLabel} is marked as sent, but the message wasn’t sent.`
              : 'The message wasn’t sent.'}
          </p>
          <p className="mt-0.5">
            {errorMessage(failure)}
            <BillingErrorLink error={failure} />
          </p>
        </div>
      )}

      {offerLink && (
        <div className="flex flex-wrap items-center gap-2">
          <p className="text-muted min-w-0 flex-1 text-sm break-all">{link}</p>
          <Button
            variant="secondary"
            size="sm"
            leadingIcon={<Copy className="size-4" aria-hidden="true" />}
            onClick={() => void copy()}
          >
            Copy link
          </Button>
        </div>
      )}

      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={busy}>
          {markedSent ? 'Close' : 'Cancel'}
        </Button>
        <Button onClick={() => void submit()} loading={busy} disabled={!ready || offerLink}>
          {choice === 'none'
            ? 'Mark as sent'
            : failure !== null
              ? 'Try again'
              : `Send ${channel === 'sms' ? 'text' : 'email'}`}
        </Button>
      </div>
    </div>
  );
}
