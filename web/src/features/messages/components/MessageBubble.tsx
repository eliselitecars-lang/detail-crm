import { AlertCircle, Mail, MessageSquare } from 'lucide-react';
import { Badge, StatusBadge } from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatDateTime, formatTime } from '@/lib/dates';
import { TEMPLATE_LABELS, type Message } from '../model';

export interface MessageBubbleProps {
  message: Message;
  timeZone: string;
}

/** One message: inbound on the left, outbound (staff/automations) on the right. */
export function MessageBubble({ message, timeZone }: MessageBubbleProps) {
  const inbound = message.direction === 'inbound';
  const ChannelIcon = message.channel === 'sms' ? MessageSquare : Mail;
  const when = message.sent_at ?? message.created_at;
  // Queued for later (campaign send time / automation) rather than "sending now".
  const scheduled =
    message.status === 'queued' &&
    new Date(message.send_after).getTime() - new Date(message.created_at).getTime() > 60_000;
  return (
    <li className={cn('flex', inbound ? 'justify-start' : 'justify-end')}>
      <article
        aria-label={`${inbound ? 'Received' : 'Sent'} ${message.channel === 'sms' ? 'text' : 'email'}, ${formatDateTime(when, timeZone)}`}
        className={cn(
          'rounded-card shadow-card max-w-[85%] px-3.5 py-2.5 text-sm sm:max-w-[75%]',
          inbound
            ? 'bg-surface-2 text-ink rounded-bl-sm'
            : 'bg-primary-soft text-ink rounded-br-sm',
          message.status === 'failed' && 'ring-danger/40 ring-1',
        )}
      >
        {message.channel === 'email' && message.subject && (
          <p className="text-ink mb-1 font-semibold break-words">{message.subject}</p>
        )}
        <p className="break-words whitespace-pre-wrap">{message.body || '(no text)'}</p>
        <footer className="text-muted mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
          <ChannelIcon className="size-3.5" aria-hidden="true" />
          <time dateTime={when} title={formatDateTime(when, timeZone)}>
            {formatTime(when, timeZone)}
          </time>
          {!inbound && message.template_key && (
            <span>· {TEMPLATE_LABELS[message.template_key]}</span>
          )}
          {!inbound && message.campaign_id && <span>· Campaign</span>}
          {!inbound &&
            (scheduled ? (
              <Badge tone="neutral">Scheduled {formatDateTime(message.send_after, timeZone)}</Badge>
            ) : (
              <StatusBadge kind="message" status={message.status} />
            ))}
        </footer>
        {message.status === 'failed' && message.error && (
          <p className="text-danger-ink mt-1.5 flex items-start gap-1 text-xs">
            <AlertCircle className="mt-px size-3.5 shrink-0" aria-hidden="true" />
            <span>{message.error}</span>
          </p>
        )}
      </article>
    </li>
  );
}
