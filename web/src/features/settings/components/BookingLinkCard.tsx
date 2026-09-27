import { Copy, ExternalLink } from 'lucide-react';
import { Badge, Button, buttonClasses, SectionCard, useToast } from '@/components/ui';
import { bookingUrl } from '../links';

export function BookingLinkCard({ slug, enabled }: { slug: string; enabled: boolean }) {
  const toast = useToast();
  const url = bookingUrl(slug);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(url);
      toast.success('Booking link copied');
    } catch {
      toast.error('Couldn’t copy the link', 'Select the link and copy it manually.');
    }
  };

  return (
    <SectionCard
      title="Your booking link"
      description="Share it on your website, Google profile and social media."
      actions={
        <Badge tone={enabled ? 'success' : 'neutral'} dot>
          {enabled ? 'Taking bookings' : 'Booking off'}
        </Badge>
      }
    >
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
        <output
          aria-label="Booking link"
          className="border-line bg-surface-2 rounded-control text-ink min-w-0 flex-1 truncate border px-3 py-2 font-mono text-sm select-all"
        >
          {url}
        </output>
        <div className="flex shrink-0 gap-2">
          <Button
            variant="secondary"
            leadingIcon={<Copy className="size-4" aria-hidden="true" />}
            onClick={() => void copy()}
          >
            Copy link
          </Button>
          <a
            href={url}
            target="_blank"
            rel="noreferrer"
            className={buttonClasses({ variant: 'ghost' })}
          >
            <ExternalLink className="size-4" aria-hidden="true" />
            Open
            <span className="sr-only"> booking page in a new tab</span>
          </a>
        </div>
      </div>
      {!enabled && (
        <p className="text-muted mt-2 text-xs">
          Turn on online booking below so customers can book from this page.
        </p>
      )}
    </SectionCard>
  );
}
