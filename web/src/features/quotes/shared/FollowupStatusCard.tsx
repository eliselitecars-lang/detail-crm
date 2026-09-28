import { BellRing } from 'lucide-react';
import { Link } from 'react-router';
import { ErrorState, LoadingState, SectionCard, Switch, useToast } from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useCan } from '@/features/shop/useCan';
import {
  followupAttemptsText,
  followupStageLabel,
  useFollowupStatus,
  useSetFollowupsPaused,
  type FollowupKind,
  type FollowupStatus,
} from './followups';

export interface FollowupStatusCardProps {
  kind: FollowupKind;
  /** quote id / job id (deposit) / invoice id */
  documentId: string;
  timezone: string;
  /** "quote", "invoice", "appointment" — used in the copy. */
  noun: string;
}

/**
 * Automatic reminders for one document: what the server will send next and
 * how many went out, with a pause switch (managers+). Hidden when the server
 * has nothing to report.
 */
export function FollowupStatusCard({ kind, documentId, timezone, noun }: FollowupStatusCardProps) {
  const status = useFollowupStatus(kind, documentId);
  if (status.isPending) {
    return (
      <SectionCard title="Automatic reminders">
        <LoadingState variant="rows" rows={1} label="Loading reminders…" />
      </SectionCard>
    );
  }
  if (status.isError) {
    return (
      <SectionCard title="Automatic reminders">
        <ErrorState compact error={status.error} onRetry={() => void status.refetch()} />
      </SectionCard>
    );
  }
  if (!status.data) return null;
  return (
    <FollowupStatusBody
      status={status.data}
      kind={kind}
      documentId={documentId}
      timezone={timezone}
      noun={noun}
    />
  );
}

function FollowupStatusBody({
  status,
  kind,
  documentId,
  timezone,
  noun,
}: {
  status: FollowupStatus;
  kind: FollowupKind;
  documentId: string;
  timezone: string;
  noun: string;
}) {
  const toast = useToast();
  const canViewSettings = useCan('settings.view');
  const setPaused = useSetFollowupsPaused(kind, documentId);
  const attempts = followupAttemptsText(status);

  const toggle = async (on: boolean) => {
    try {
      await setPaused.mutateAsync(!on);
      toast.success(on ? 'Reminders resumed' : `Reminders paused for this ${noun}`);
    } catch (error) {
      toast.error(error);
    }
  };

  let summary: string;
  if (!status.enabled) {
    summary = 'Turned off for your shop.';
  } else if (status.paused) {
    summary = `Paused for this ${noun}. Nothing more is sent until you resume them.`;
  } else if (status.next_at) {
    summary = `Next reminder ${formatDateTime(status.next_at, timezone)} (shop time).`;
  } else if (status.max_attempts > 0 && status.attempts_sent >= status.max_attempts) {
    summary = 'Every reminder has been sent.';
  } else {
    summary = `No reminder is due: this ${noun} doesn’t need one right now.`;
  }

  return (
    <SectionCard
      title={
        <span className="inline-flex items-center gap-2">
          <BellRing className="text-muted size-4" aria-hidden="true" />
          {followupStageLabel(status.stage)}
        </span>
      }
    >
      <div className="flex flex-col gap-3 text-sm">
        <p className="text-ink" role="status">
          {summary}
        </p>
        {(attempts || status.last_sent_at) && (
          <p className="text-muted text-xs">
            {[
              attempts,
              status.last_sent_at
                ? `last sent ${formatDateTime(status.last_sent_at, timezone)}`
                : null,
            ]
              .filter(Boolean)
              .join(' · ')}
          </p>
        )}
        {status.enabled ? (
          <Switch
            checked={!status.paused}
            onCheckedChange={(on) => void toggle(on)}
            disabled={setPaused.isPending}
            label={`Remind the customer about this ${noun}`}
            description="Uses your follow-up schedule and message templates."
          />
        ) : (
          canViewSettings && (
            <Link
              to="/app/settings/followups"
              className="text-primary-ink text-sm font-medium hover:underline"
            >
              Set up follow-ups
            </Link>
          )
        )}
      </div>
    </SectionCard>
  );
}
