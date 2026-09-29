import { Download, FileText, Film, Images, Star } from 'lucide-react';
import { useParams } from 'react-router';
import { PublicLayout, type PublicShopBranding } from '@/components/layout/PublicLayout';
import { Badge, SectionCard, Spinner, buttonClasses, formatBytes } from '@/components/ui';
import { formatLocalDate } from '@/lib/dates';
import {
  DocumentTitle,
  PublicError,
  PublicLoading,
} from '@/features/public-docs/shared/PublicPage';
import { isLinkToken } from '@/features/public-docs/shared/schemas';
import { useJobReport, useReportMedia, type JobReport, type ReportPhoto } from './api';
import { InspectionsSection } from './components/InspectionsSection';
import { documentTypeLabel, mediaKey } from './media';
import { pairBeforeAfter, photoLabel, vehicleText } from './model';

export default function JobReportPage() {
  const { token } = useParams();
  if (!isLinkToken(token)) return <PublicError error={null} what="job report" />;
  return <JobReportView token={token} />;
}

function JobReportView({ token }: { token: string }) {
  const report = useJobReport(token);
  if (report.isPending) return <PublicLoading label="Loading your job report…" />;
  if (report.isError) {
    return (
      <PublicError
        error={report.error}
        what="job report"
        onRetry={() => void report.refetch()}
        retrying={report.isFetching}
      />
    );
  }
  return <ReportBody token={token} report={report.data} />;
}

function branding(report: JobReport): PublicShopBranding {
  return {
    name: report.shop.name,
    logoPath: report.shop.logo_path,
    brandColor: report.shop.brand_color,
    phone: report.shop.phone,
    email: report.shop.email,
  };
}

function ReportBody({ token, report }: { token: string; report: JobReport }) {
  const hasMedia =
    report.photos.length > 0 ||
    report.documents.length > 0 ||
    report.inspections.some((i) => i.marks.some((m) => m.has_photo));
  const media = useReportMedia(token, hasMedia);
  const urls = media.data ?? new Map<string, string>();
  const images = report.photos.filter((p) => p.media_type === 'image');
  const videos = report.photos.filter((p) => p.media_type === 'video');
  const { pairs, rest } = pairBeforeAfter(images);
  const vehicle = vehicleText(report.vehicle);

  return (
    <PublicLayout shop={branding(report)} title="Your job report">
      <div className="flex flex-col gap-4 sm:gap-5">
        <DocumentTitle
          title="Your job report"
          badge={
            report.job.status === 'completed' ? <Badge tone="success">Completed</Badge> : undefined
          }
          subtitle={[
            `Job #${report.job.number}`,
            formatLocalDate(report.job.local_date, 'MMMM d, yyyy'),
            vehicle,
          ]
            .filter(Boolean)
            .join(' · ')}
        />

        {report.message && (
          <SectionCard title={`A note from ${report.shop.name}`}>
            <p className="text-ink text-sm whitespace-pre-line">{report.message}</p>
          </SectionCard>
        )}

        {report.services.length > 0 && (
          <SectionCard title="What we did">
            <ul className="text-ink flex list-disc flex-col gap-1 pl-5 text-sm">
              {report.services.map((name, i) => (
                <li key={`${name}-${i}`}>{name}</li>
              ))}
            </ul>
          </SectionCard>
        )}

        {media.isError && hasMedia && (
          <p role="alert" className="text-danger-ink text-sm">
            Photos and files couldn’t be loaded right now.{' '}
            <button
              type="button"
              className="font-medium underline"
              onClick={() => void media.refetch()}
            >
              Try again
            </button>
          </p>
        )}

        {pairs.length > 0 && (
          <SectionCard title="Before & after">
            <div className="flex flex-col gap-4">
              {pairs.map((pair, i) => (
                <div
                  key={`${pair.before.id}-${pair.after.id}`}
                  className="grid gap-2 sm:grid-cols-2"
                >
                  <PhotoTile
                    photo={pair.before}
                    url={urls.get(mediaKey('photo', pair.before.id))}
                    loading={media.isPending}
                    label={photoLabel(pair.before, i)}
                    tag="Before"
                  />
                  <PhotoTile
                    photo={pair.after}
                    url={urls.get(mediaKey('photo', pair.after.id))}
                    loading={media.isPending}
                    label={photoLabel(pair.after, i)}
                    tag="After"
                  />
                </div>
              ))}
            </div>
          </SectionCard>
        )}

        {rest.length > 0 && (
          <SectionCard title={pairs.length > 0 ? 'More photos' : 'Photos'}>
            <ul className="grid grid-cols-2 gap-2 sm:grid-cols-3" aria-label="Photos">
              {rest.map((photo, i) => (
                <li key={photo.id}>
                  <PhotoTile
                    photo={photo}
                    url={urls.get(mediaKey('photo', photo.id))}
                    loading={media.isPending}
                    label={photoLabel(photo, i)}
                  />
                </li>
              ))}
            </ul>
          </SectionCard>
        )}

        {videos.length > 0 && (
          <SectionCard title="Videos">
            <ul className="grid gap-3 sm:grid-cols-2" aria-label="Videos">
              {videos.map((video, i) => (
                <li key={video.id} className="flex flex-col gap-1">
                  <VideoTile
                    video={video}
                    url={urls.get(mediaKey('video', video.id))}
                    poster={urls.get(mediaKey('poster', video.id))}
                    loading={media.isPending}
                    label={photoLabel(video, i)}
                  />
                </li>
              ))}
            </ul>
          </SectionCard>
        )}

        {report.inspections.length > 0 && (
          <InspectionsSection token={token} report={report} urls={urls} />
        )}

        {report.documents.length > 0 && (
          <SectionCard title="Documents" flush>
            <ul className="divide-line divide-y px-4 sm:px-5" aria-label="Documents">
              {report.documents.map((doc) => {
                const url = urls.get(mediaKey('document', doc.id));
                return (
                  <li key={doc.id} className="flex items-center gap-3 py-3">
                    <FileText className="text-muted size-5 shrink-0" aria-hidden="true" />
                    <div className="min-w-0 flex-1">
                      <p className="text-ink truncate text-sm font-medium">{doc.file_name}</p>
                      <p className="text-muted text-xs">
                        {[
                          documentTypeLabel(doc.content_type),
                          doc.size_bytes !== null ? formatBytes(doc.size_bytes) : null,
                        ]
                          .filter(Boolean)
                          .join(' · ')}
                      </p>
                    </div>
                    {url ? (
                      <a
                        href={url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-primary-ink inline-flex items-center gap-1.5 text-sm font-medium hover:underline"
                      >
                        <Download className="size-4" aria-hidden="true" />
                        Open<span className="sr-only"> {doc.file_name} (new tab)</span>
                      </a>
                    ) : media.isPending ? (
                      <Spinner className="size-4" />
                    ) : null}
                  </li>
                );
              })}
            </ul>
          </SectionCard>
        )}

        {report.photos.length === 0 &&
          report.inspections.length === 0 &&
          report.documents.length === 0 && (
            <SectionCard title="Photos">
              <p className="text-muted flex items-center gap-2 text-sm">
                <Images className="size-4" aria-hidden="true" />
                No photos were shared with this report.
              </p>
            </SectionCard>
          )}

        {report.shop.review_url && report.job.status === 'completed' && (
          <div className="rounded-card border-line bg-surface flex flex-col items-center gap-3 border p-5 text-center">
            <p className="text-ink text-sm font-medium">Happy with the result?</p>
            <a
              href={report.shop.review_url}
              target="_blank"
              rel="noopener noreferrer"
              className={buttonClasses({ variant: 'primary' })}
            >
              <Star className="size-4" aria-hidden="true" />
              Leave {report.shop.name} a review
            </a>
          </div>
        )}
      </div>
    </PublicLayout>
  );
}

function PhotoTile({
  photo,
  url,
  loading,
  label,
  tag,
}: {
  photo: ReportPhoto;
  url: string | undefined;
  loading: boolean;
  label: string;
  tag?: string;
}) {
  return (
    <figure className="flex flex-col gap-1">
      <div className="rounded-control border-line bg-surface-2 relative aspect-[4/3] overflow-hidden border">
        {url ? (
          <a href={url} target="_blank" rel="noopener noreferrer" className="block size-full">
            <img src={url} alt={label} loading="lazy" className="size-full object-cover" />
            <span className="sr-only"> (opens full size in a new tab)</span>
          </a>
        ) : (
          <div className="text-muted flex size-full items-center justify-center text-xs">
            {loading ? <Spinner className="size-5" label="Loading photo" /> : 'Photo unavailable'}
          </div>
        )}
        {tag && (
          <span className="bg-surface/90 text-ink absolute top-2 left-2 rounded px-1.5 py-0.5 text-xs font-medium">
            {tag}
          </span>
        )}
      </div>
      {photo.caption && (
        <figcaption className="text-muted text-xs break-words">{photo.caption}</figcaption>
      )}
    </figure>
  );
}

function VideoTile({
  video,
  url,
  poster,
  loading,
  label,
}: {
  video: ReportPhoto;
  url: string | undefined;
  poster: string | undefined;
  loading: boolean;
  label: string;
}) {
  return (
    <figure className="flex flex-col gap-1">
      <div className="rounded-control border-line bg-surface-2 aspect-video overflow-hidden border">
        {url ? (
          <video
            controls
            preload="metadata"
            playsInline
            src={url}
            {...(poster ? { poster } : {})}
            aria-label={label}
            className="size-full bg-black object-contain"
          >
            <track kind="captions" />
          </video>
        ) : (
          <div className="text-muted flex size-full items-center justify-center gap-2 text-xs">
            {loading ? (
              <Spinner className="size-5" label="Loading video" />
            ) : (
              <>
                <Film className="size-4" aria-hidden="true" />
                Video unavailable
              </>
            )}
          </div>
        )}
      </div>
      {(video.caption || video.duration_seconds) && (
        <figcaption className="text-muted text-xs break-words">
          {[
            video.caption,
            video.duration_seconds ? `${Math.round(video.duration_seconds)} s` : null,
          ]
            .filter(Boolean)
            .join(' · ')}
        </figcaption>
      )}
    </figure>
  );
}
