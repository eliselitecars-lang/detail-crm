import { SectionCard } from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import type { QuoteRow } from '../api';
import { quoteTimeline } from './timeline';

export function QuoteTimeline({ quote, timezone }: { quote: QuoteRow; timezone: string }) {
  const events = quoteTimeline(quote);
  return (
    <SectionCard title="Timeline">
      <ol className="border-line relative ml-1.5 flex flex-col gap-4 border-l pl-4">
        {events.map((event) => (
          <li key={event.key} className="relative">
            <span
              aria-hidden="true"
              className="bg-primary ring-surface absolute top-1.5 -left-[1.3rem] size-2.5 rounded-full ring-2"
            />
            <p className="text-ink text-sm font-medium">{event.label}</p>
            <p className="text-muted text-xs">
              <time dateTime={event.at}>{formatDateTime(event.at, timezone)}</time>
            </p>
            {event.detail && (
              <p className="text-muted mt-0.5 text-xs break-words">{event.detail}</p>
            )}
          </li>
        ))}
      </ol>
    </SectionCard>
  );
}
