import { Copy, Link2 } from 'lucide-react';
import { useState } from 'react';
import { Button, Dialog, ErrorState, FormField, Input, Textarea, useToast } from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useSendCustomerMessage } from '@/features/quotes/shared/api';
import { copyText, customerName } from '@/features/quotes/shared/format';
import {
  billingLabel,
  useMembershipCheckout,
  type CheckoutResult,
  type SubscriberRow,
} from '../api';

export type CheckoutTarget = Pick<SubscriberRow, 'id' | 'customer' | 'plan'>;

export interface CheckoutLinkDialogProps {
  membership: CheckoutTarget | null;
  onClose: () => void;
}

/** Creates a Stripe Checkout link for an incomplete membership and shares it. */
export function CheckoutLinkDialog({ membership, onClose }: CheckoutLinkDialogProps) {
  return (
    <Dialog
      open={membership !== null}
      onClose={onClose}
      title="Membership checkout link"
      description="The customer enters their card on Stripe’s secure page; the membership turns active once the first payment succeeds."
    >
      {membership && <CheckoutLinkBody membership={membership} onClose={onClose} />}
    </Dialog>
  );
}

function CheckoutLinkBody({
  membership,
  onClose,
}: {
  membership: CheckoutTarget;
  onClose: () => void;
}) {
  const toast = useToast();
  const { shop, currency } = useShop();
  const checkout = useMembershipCheckout();
  const send = useSendCustomerMessage();
  const [result, setResult] = useState<CheckoutResult | null>(null);
  const [message, setMessage] = useState('');
  const customer = membership.customer;
  const planName = membership.plan?.name ?? 'membership';

  const create = async () => {
    try {
      const next = await checkout.mutateAsync(membership.id);
      setResult(next);
      const first =
        customer?.first_name?.trim() || customer?.company?.trim() || customerName(customer);
      setMessage(
        `Hi ${first}, here is your secure link to start your ${planName} membership with ${shop.name}: ${next.url}`,
      );
    } catch (error) {
      toast.error(error);
    }
  };

  const copy = async () => {
    if (!result) return;
    if (await copyText(result.url)) toast.success('Checkout link copied');
    else toast.error('Couldn’t copy the link', result.url);
  };

  const sendVia = async (channel: 'sms' | 'email') => {
    if (!customer || !result) return;
    try {
      const sent = await send.mutateAsync({
        customerId: customer.id,
        channel,
        body: message,
        subject: `Your ${planName} membership with ${shop.name}`,
      });
      if (sent.status === 'failed') {
        toast.show({
          tone: 'error',
          title: 'The message failed',
          description: sent.error ?? undefined,
        });
        return;
      }
      toast.success(channel === 'sms' ? 'Link texted' : 'Link emailed');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  const canText = Boolean(customer?.phone) && !customer?.sms_opted_out_at;
  const canEmail = Boolean(customer?.email) && !customer?.email_opted_out_at;
  const tooLong = message.length > 1600;

  if (!result) {
    return (
      <div className="flex flex-col gap-4">
        <p className="text-ink text-sm">
          {customerName(customer)} ·{' '}
          {membership.plan
            ? billingLabel(
                formatCents(membership.plan.price_cents, { currency }),
                membership.plan.interval,
                membership.plan.interval_count,
              )
            : planName}
        </p>
        {checkout.isError && (
          <ErrorState compact error={checkout.error} title="Couldn’t create the link" />
        )}
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>
            Close
          </Button>
          <Button
            variant="money"
            leadingIcon={<Link2 className="size-4" aria-hidden="true" />}
            loading={checkout.isPending}
            onClick={() => void create()}
          >
            Create checkout link
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      <FormField
        label="Checkout link"
        help="Links expire after a while; create a new one if needed."
      >
        <Input
          readOnly
          value={result.url}
          onFocus={(event) => event.currentTarget.select()}
          trailing={
            <button
              type="button"
              className="text-primary-ink hover:text-ink inline-flex items-center gap-1 text-xs font-medium"
              onClick={() => void copy()}
            >
              <Copy className="size-3.5" aria-hidden="true" />
              Copy
            </button>
          }
        />
      </FormField>
      <FormField
        label="Message"
        error={tooLong ? 'Text messages are limited to 1,600 characters.' : undefined}
        help={
          !canText && !canEmail
            ? 'This customer can’t be messaged; copy the link instead.'
            : undefined
        }
      >
        <Textarea rows={4} value={message} onChange={(event) => setMessage(event.target.value)} />
      </FormField>
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={send.isPending}>
          Done
        </Button>
        {canEmail && (
          <Button
            variant="secondary"
            onClick={() => void sendVia('email')}
            loading={send.isPending && send.variables?.channel === 'email'}
            disabled={send.isPending || message.trim() === ''}
          >
            Email it
          </Button>
        )}
        {canText && (
          <Button
            onClick={() => void sendVia('sms')}
            loading={send.isPending && send.variables?.channel === 'sms'}
            disabled={send.isPending || tooLong || message.trim() === ''}
          >
            Text it
          </Button>
        )}
      </div>
    </div>
  );
}
