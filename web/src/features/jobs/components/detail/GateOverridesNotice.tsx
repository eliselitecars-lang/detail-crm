import { ShieldAlert } from 'lucide-react';
import { ErrorState, statusLabel } from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useGateOverrides, useTeam, type GateOverride } from '../../api';
import { waivedBlockers } from '../../model';

/**
 * P-11 audit trail on the job page: each time a manager moved the job past
 * its required checklist items or photo minimums (set_job_status with
 * force), who did it, when, why, and what was still missing. Nothing is
 * shown for a job that never needed an override.
 */
export function GateOverridesNotice({ jobId }: { jobId: string }) {
  const overrides = useGateOverrides(jobId);
  if (overrides.isPending) return null; // secondary information: no spinner on the job page
  if (overrides.isError) {
    return (
      <div className="mb-4">
        <ErrorState
          compact
          title="Couldn’t load the requirement overrides"
          error={overrides.error}
          onRetry={() => void overrides.refetch()}
          retrying={overrides.isRefetching}
        />
      </div>
    );
  }
  if (overrides.data.length === 0) return null;
  return (
    <section
      aria-label="Requirement overrides"
      className="border-warning bg-warning-soft rounded-card mb-4 flex flex-col gap-3 border px-4 py-3"
    >
      {overrides.data.map((override) => (
        <OverrideEntry key={override.id} override={override} />
      ))}
    </section>
  );
}

function OverrideEntry({ override }: { override: GateOverride }) {
  const { timezone } = useShop();
  const team = useTeam();
  const who = override.overridden_by
    ? team.data?.find((m) => m.userId === override.overridden_by)?.name
    : undefined;
  const waived = waivedBlockers(override.blockers);
  const status = statusLabel('job', override.to_status);

  return (
    <div className="text-warning-ink flex gap-2.5 text-sm">
      <ShieldAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
      <div className="flex min-w-0 flex-col gap-1">
        <p className="font-medium">
          Moved to {status} without meeting its requirements
          <span className="font-normal">
            {' · '}
            {formatDateTime(override.created_at, timezone)}
            {who ? ` · by ${who}` : ''}
          </span>
        </p>
        <p className="break-words whitespace-pre-wrap">
          <span className="font-medium">Reason: </span>
          {override.reason?.trim() ? override.reason : 'No reason given.'}
        </p>
        {waived.length > 0 && (
          <ul className="list-disc pl-5" aria-label="Requirements that were not met">
            {waived.map((b) => (
              <li key={b.key}>{b.text}</li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
