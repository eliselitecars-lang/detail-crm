import { CheckCircle2, Navigation } from 'lucide-react';
import { useState } from 'react';
import {
  Button,
  ErrorState,
  LoadingState,
  SectionCard,
  Select,
  StatusBadge,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import type { JobDetail } from '../../api';
import { useJobMessages, useSendJobTemplate, type JobTemplateKey } from '../../fieldApi';

const TEMPLATE_LABELS: Record<JobTemplateKey, string> = {
  on_the_way: '“On my way”',
  job_completed: '“Job complete”',
};

export function MessagesCard({ job }: { job: JobDetail }) {
  const { timezone } = useShop();
  const canSend = useCan('messages.sendJobUpdates');
  const canReadInbox = useCan('messages.inbox');
  const toast = useToast();
  const messages = useJobMessages(job.id, job.customer_id, canReadInbox);
  const send = useSendJobTemplate(job.id);
  const [channel, setChannel] = useState<'sms' | 'email'>(job.customer?.phone ? 'sms' : 'email');

  if (!canSend && !canReadInbox) return null;
  const closed = job.status === 'cancelled' || job.status === 'no_show';

  const onSend = async (templateKey: JobTemplateKey) => {
    try {
      const result = await send.mutateAsync({ templateKey, channel });
      if (result.status === 'failed') {
        toast.error('The message could not be delivered', result.error ?? undefined);
      } else {
        toast.success(`${TEMPLATE_LABELS[templateKey]} sent`);
      }
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard title="Messages" level={3}>
      <div className="flex flex-col gap-3">
        {canSend && !closed && (
          <div className="flex flex-col gap-2">
            <Select
              aria-label="Send by"
              selectSize="sm"
              value={channel}
              onChange={(e) => setChannel(e.target.value === 'email' ? 'email' : 'sms')}
              options={[
                { value: 'sms', label: 'Text message' },
                { value: 'email', label: 'Email' },
              ]}
            />
            <div className="flex flex-wrap gap-2">
              <Button
                size="sm"
                variant="secondary"
                loading={send.isPending && send.variables.templateKey === 'on_the_way'}
                disabled={send.isPending}
                leadingIcon={<Navigation className="size-4" aria-hidden="true" />}
                onClick={() => void onSend('on_the_way')}
              >
                On my way
              </Button>
              <Button
                size="sm"
                variant="secondary"
                loading={send.isPending && send.variables.templateKey === 'job_completed'}
                disabled={send.isPending}
                leadingIcon={<CheckCircle2 className="size-4" aria-hidden="true" />}
                onClick={() => void onSend('job_completed')}
              >
                Job complete
              </Button>
            </div>
          </div>
        )}
        {canReadInbox &&
          (messages.isPending ? (
            <LoadingState label="Loading messages…" />
          ) : messages.isError ? (
            <ErrorState compact error={messages.error} onRetry={() => void messages.refetch()} />
          ) : messages.data.length === 0 ? (
            <p className="text-muted text-sm">No messages with this customer yet.</p>
          ) : (
            <ul className="flex flex-col gap-3">
              {messages.data.map((m) => (
                <li key={m.id} className="border-line rounded-control border p-2.5 text-sm">
                  <div className="text-muted mb-1 flex flex-wrap items-center justify-between gap-2 text-xs">
                    <span>
                      {m.direction === 'inbound' ? 'From customer' : 'To customer'} ·{' '}
                      {m.channel === 'sms' ? 'Text' : 'Email'} ·{' '}
                      {formatDateTime(m.created_at, timezone)}
                      {m.job_id === null ? ' · not linked to a job' : ''}
                    </span>
                    <StatusBadge kind="message" status={m.status} />
                  </div>
                  {m.subject && <p className="text-ink font-medium">{m.subject}</p>}
                  <p className="text-ink line-clamp-3 whitespace-pre-line">{m.body}</p>
                  {m.status === 'failed' && m.error && (
                    <p className="text-danger-ink mt-1 text-xs">{m.error}</p>
                  )}
                </li>
              ))}
            </ul>
          ))}
      </div>
    </SectionCard>
  );
}
