import { Share2 } from 'lucide-react';
import { useState } from 'react';
import {
  Button,
  buttonClasses,
  ConfirmDialog,
  CopyField,
  ErrorState,
  LoadingState,
  SectionCard,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import type { JobDetail } from '../../api';
import { useInspections, usePhotos } from '../../fieldApi';
import { reportLink, useJobReport, useRevokeJobReport } from '../../reportApi';
import { ShareReportDialog } from './ShareReportDialog';

/**
 * The customer-facing job report (P-8): share / update / revoke the link and
 * see whether the customer opened it or signed the inspection remotely.
 * Managers always; technicians on the job only when the shop allows it.
 */
export function ReportCard({ job }: { job: JobDetail }) {
  const { timezone } = useShop();
  const canShare = useCan('jobs.shareReport');
  const canRevoke = useCan('jobs.manage');
  const toast = useToast();
  const report = useJobReport(job.id, canShare);
  const photos = usePhotos(job.id);
  const inspections = useInspections(job.id);
  const revoke = useRevokeJobReport(job.id);
  const [sharing, setSharing] = useState(false);
  const [revoking, setRevoking] = useState(false);
  /** The server's link from the last publish (it knows the app's address). */
  const [serverUrl, setServerUrl] = useState<{ token: string; url: string } | null>(null);

  if (!canShare) return null;
  const live = report.data ?? null;
  const url = live
    ? serverUrl?.token === live.token
      ? serverUrl.url
      : reportLink(window.location.origin, live.token)
    : null;
  const remoteSign = (inspections.data ?? []).find((i) => i.signed_remotely && i.signed_at);
  const closed = job.status === 'cancelled' || job.status === 'no_show';

  return (
    <SectionCard
      title="Customer report"
      level={3}
      actions={
        live ? undefined : (
          <Button
            size="sm"
            variant="secondary"
            leadingIcon={<Share2 className="size-4" aria-hidden="true" />}
            disabled={report.isPending || closed}
            onClick={() => setSharing(true)}
          >
            Share
          </Button>
        )
      }
    >
      {report.isPending ? (
        <LoadingState label="Loading report…" />
      ) : report.isError ? (
        <ErrorState compact error={report.error} onRetry={() => void report.refetch()} />
      ) : !live || !url ? (
        <p className="text-muted text-sm">
          {closed
            ? 'Reports can’t be shared for cancelled jobs.'
            : 'Send the customer a private page with their before / after photos, inspection and shared files.'}
        </p>
      ) : (
        <div className="flex flex-col gap-3">
          <ul className="text-ink flex flex-col gap-1 text-sm">
            <li>Shared {formatDateTime(live.published_at, timezone)}</li>
            <li className={live.first_viewed_at ? undefined : 'text-muted'}>
              {live.first_viewed_at
                ? `Opened ${formatDateTime(live.first_viewed_at, timezone)}`
                : 'Not opened yet'}
            </li>
            {remoteSign?.signed_at && (
              <li>
                Inspection signed by {remoteSign.signed_by_name ?? 'the customer'} from the report ·{' '}
                {formatDateTime(remoteSign.signed_at, timezone)}
              </li>
            )}
          </ul>
          <CopyField
            label="Report link"
            value={url}
            copiedMessage="Link copied"
            actions={
              <a
                href={url}
                target="_blank"
                rel="noreferrer"
                className={buttonClasses({ variant: 'ghost', size: 'sm' })}
              >
                Open
                <span className="sr-only"> the report in a new tab</span>
              </a>
            }
          />
          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant="secondary" onClick={() => setSharing(true)}>
              Update or resend
            </Button>
            {canRevoke && (
              <Button size="sm" variant="ghost" onClick={() => setRevoking(true)}>
                Turn off link
              </Button>
            )}
          </div>
        </div>
      )}
      {sharing && (
        <ShareReportDialog
          job={job}
          report={live}
          photos={photos.data ?? []}
          onClose={() => setSharing(false)}
          onPublished={(result) => {
            if (result.url) setServerUrl({ token: result.token, url: result.url });
          }}
        />
      )}
      <ConfirmDialog
        open={revoking}
        onClose={() => setRevoking(false)}
        tone="danger"
        title="Turn off the report link?"
        description="The customer’s link stops working. Sharing again creates a new link."
        confirmLabel="Turn off link"
        loading={revoke.isPending}
        onConfirm={async () => {
          if (!live) return;
          try {
            await revoke.mutateAsync(live.id);
            toast.success('Report link turned off');
            setRevoking(false);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}
