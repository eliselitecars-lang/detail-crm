import { Code, ExternalLink, QrCode as QrIcon } from 'lucide-react';
import { useState } from 'react';
import { Badge, Button, buttonClasses, CopyField, QrCode, SectionCard } from '@/components/ui';
import { bookingUrl } from '../links';
import { EmbedSnippets } from './EmbedSnippets';

export function BookingLinkCard({ slug, enabled }: { slug: string; enabled: boolean }) {
  const url = bookingUrl(slug);
  const [panel, setPanel] = useState<'qr' | 'embed' | null>(null);

  return (
    <SectionCard
      title="Your booking link"
      description="Share it on your website, Google profile and social media, print its QR code, or put the booking page right on your website."
      actions={
        <Badge tone={enabled ? 'success' : 'neutral'} dot>
          {enabled ? 'Taking bookings' : 'Booking off'}
        </Badge>
      }
    >
      <div className="flex flex-col gap-3">
        <CopyField
          value={url}
          label="Booking link"
          copiedMessage="Booking link copied"
          actions={
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
          }
        />
        <div className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            size="sm"
            leadingIcon={<QrIcon className="size-4" aria-hidden="true" />}
            aria-expanded={panel === 'qr'}
            onClick={() => setPanel(panel === 'qr' ? null : 'qr')}
          >
            QR code
          </Button>
          <Button
            variant="secondary"
            size="sm"
            leadingIcon={<Code className="size-4" aria-hidden="true" />}
            aria-expanded={panel === 'embed'}
            onClick={() => setPanel(panel === 'embed' ? null : 'embed')}
          >
            Embed on your website
          </Button>
        </div>
        {panel === 'qr' && (
          <QrCode value={url} label="QR code for your booking page" fileName={`${slug}-booking`} />
        )}
        {panel === 'embed' && <EmbedSnippets target={{ slug }} title="Book online" />}
        {!enabled && (
          <p className="text-muted text-xs">
            Turn on online booking below so customers can book from this page.
          </p>
        )}
      </div>
    </SectionCard>
  );
}
