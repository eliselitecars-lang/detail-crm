import type { QuoteRow } from '../api';

export interface TimelineEvent {
  key: string;
  at: string;
  label: string;
  detail?: string | null;
}

export function quoteTimeline(quote: QuoteRow): TimelineEvent[] {
  const events: (TimelineEvent | null)[] = [
    { key: 'created', at: quote.created_at, label: 'Created' },
    quote.sent_at ? { key: 'sent', at: quote.sent_at, label: 'Sent to customer' } : null,
    quote.viewed_at ? { key: 'viewed', at: quote.viewed_at, label: 'Viewed by customer' } : null,
    quote.approved_at
      ? {
          key: 'approved',
          at: quote.approved_at,
          label: 'Approved',
          detail: quote.approved_by_name ? `Signed by ${quote.approved_by_name}` : null,
        }
      : null,
    quote.declined_at
      ? { key: 'declined', at: quote.declined_at, label: 'Declined', detail: quote.declined_reason }
      : null,
    quote.expired_at ? { key: 'expired', at: quote.expired_at, label: 'Expired' } : null,
    quote.converted_at
      ? { key: 'converted', at: quote.converted_at, label: 'Converted to a job' }
      : null,
  ];
  return events
    .filter((e): e is TimelineEvent => e !== null)
    .sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0));
}
