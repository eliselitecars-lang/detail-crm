import { Download, FileText } from 'lucide-react';
import { ErrorState, SectionCard, Spinner, formatBytes } from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { documentTypeLabel, mediaKey } from '@/features/job-report/media';
import { useBookingDocumentMedia, useBookingDocuments } from '../api';
import { useTrackingActive } from '../tracking';

/**
 * Documents the shop shared on this booking (P-25): public_booking_documents
 * lists them; the public-media function signs 10-minute download links,
 * refreshed before they expire. Nothing renders when there are none.
 * While a shop's tag is loaded on this page (tracking.ts) the links are
 * buttons, so the tag's outbound-click / file-download listeners never
 * record a signed URL.
 */
const openClass =
  'text-primary-ink inline-flex shrink-0 items-center gap-1.5 text-sm font-medium hover:underline';

export function BookingDocumentsCard({ token, timeZone }: { token: string; timeZone: string }) {
  const documents = useBookingDocuments(token, true);
  const count = documents.data?.length ?? 0;
  const media = useBookingDocumentMedia(token, count > 0);
  const tracking = useTrackingActive();

  if (documents.isPending || (documents.isSuccess && count === 0)) return null;
  if (documents.isError) {
    return (
      <SectionCard title="Documents">
        <ErrorState
          compact
          error={documents.error}
          title="Couldn’t load the documents"
          onRetry={() => void documents.refetch()}
          retrying={documents.isFetching}
        />
      </SectionCard>
    );
  }

  return (
    <SectionCard title="Documents" description="Shared with you by the shop." flush>
      {media.isError && (
        <div className="border-line border-b">
          <ErrorState
            compact
            error={media.error}
            title="Couldn’t prepare the download links"
            onRetry={() => void media.refetch()}
            retrying={media.isFetching}
          />
        </div>
      )}
      <ul className="divide-line divide-y px-4 sm:px-5" aria-label="Documents">
        {documents.data.map((doc) => {
          const url = media.data?.get(mediaKey('document', doc.id));
          return (
            <li key={doc.id} className="flex items-center gap-3 py-3">
              <span className="bg-surface-2 text-muted flex size-9 shrink-0 items-center justify-center rounded-full">
                <FileText className="size-4" aria-hidden="true" />
              </span>
              <div className="min-w-0 flex-1">
                <p className="text-ink truncate text-sm font-medium">{doc.file_name}</p>
                <p className="text-muted text-xs">
                  {[
                    documentTypeLabel(doc.content_type),
                    doc.size_bytes !== null ? formatBytes(doc.size_bytes) : null,
                    doc.created_at ? formatDate(doc.created_at, timeZone) : null,
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              </div>
              {url && tracking ? (
                <button
                  type="button"
                  onClick={() => window.open(url, '_blank', 'noopener,noreferrer')}
                  className={openClass}
                >
                  <Download className="size-4" aria-hidden="true" />
                  Open<span className="sr-only"> {doc.file_name} (new tab)</span>
                </button>
              ) : url ? (
                <a href={url} target="_blank" rel="noopener noreferrer" className={openClass}>
                  <Download className="size-4" aria-hidden="true" />
                  Open<span className="sr-only"> {doc.file_name} (new tab)</span>
                </a>
              ) : media.isPending ? (
                <Spinner className="size-4 shrink-0" />
              ) : (
                <span className="text-subtle shrink-0 text-xs">Unavailable</span>
              )}
            </li>
          );
        })}
      </ul>
    </SectionCard>
  );
}
