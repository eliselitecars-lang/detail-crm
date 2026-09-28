import { Ban, Check, UserX } from 'lucide-react';
import { useId, useState } from 'react';
import {
  Button,
  ConfirmDialog,
  Dialog,
  FormField,
  statusLabel,
  Textarea,
  useToast,
} from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatDateTime } from '@/lib/dates';
import { errorMessage, toAppError } from '@/lib/errors';
import { EdgeFunctionError } from '@/features/quotes/shared/edge';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import {
  fetchCompletionBlockers,
  useReleaseJobPayments,
  useSetStatus,
  useStatusTransitions,
  type JobDetail,
} from '../../api';
import {
  allowedTransitions,
  gateBlockers,
  isGatedMove,
  statusNeedsSchedule,
  statusSteps,
  type GateBlocker,
  type JobStatus,
  type StatusTransition,
} from '../../model';

/** Longest reason set_job_status accepts (cancel reason / gate override). */
const REASON_MAX = 500;

export interface StatusControlProps {
  job: JobDetail;
}

/**
 * Status stepper: only the transitions the role may take (job_status_
 * transitions + role, mirroring jobs_status_machine) are clickable. Backward
 * moves and side exits ask for confirmation; the server re-validates.
 */
export function StatusControl({ job }: StatusControlProps) {
  const { role, timezone } = useShop();
  const toast = useToast();
  const transitions = useStatusTransitions();
  const setStatus = useSetStatus(job.id);
  const release = useReleaseJobPayments(job.id);
  const canCollect = useCan('payments.collect');
  const canOverride = useCan('jobs.manage');
  const [confirming, setConfirming] = useState<StatusTransition | null>(null);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [reason, setReason] = useState('');
  /** A card payment on the job is still processing: the side exit must wait. */
  const [held, setHeld] = useState(false);
  /** The completion gates block this move (P-11): what is missing. */
  const [gate, setGate] = useState<{ status: JobStatus; blockers: GateBlocker[] } | null>(null);
  const [overrideReason, setOverrideReason] = useState('');
  const [checking, setChecking] = useState(false);
  const busy = setStatus.isPending || release.isPending || checking;

  /**
   * Before cancelling / no-show: release the job's open card payments and pay
   * links. False (with the reason shown) when the status must not change yet.
   */
  const releasePayments = async (): Promise<boolean> => {
    if (!canCollect) return true; // this role never starts card payments
    try {
      const result = await release.mutateAsync();
      if (result.in_progress > 0) {
        setHeld(true);
        return false;
      }
      if (result.succeeded > 0) {
        toast.info(
          result.succeeded === 1 ? 'A card payment was recorded' : 'Card payments were recorded',
          'Money that had already gone through for this job is on its invoice or deposit.',
        );
      }
      return true;
    } catch (error) {
      if (error instanceof EdgeFunctionError && error.reason === 'payment_in_progress') {
        setHeld(true);
      } else {
        toast.error(error);
      }
      return false;
    }
  };

  const allowed = allowedTransitions(transitions.data ?? [], job.status, role);
  const steps = statusSteps(job.status, allowed);
  /**
   * Steps the role could take but that wait for a date and time. Said in
   * visible text (a hover title never shows on touch and isn't reliably
   * announced on a non-focusable element).
   */
  const scheduleHintId = useId();
  const waitingForSchedule = job.scheduled_start
    ? []
    : steps.filter((s) => s.transition !== null && statusNeedsSchedule(s.status));
  const cancelEdge = allowed.find((t) => t.to_status === 'cancelled') ?? null;
  const noShowEdge = allowed.find((t) => t.to_status === 'no_show') ?? null;

  /** The gates' current state for a move (null when nothing blocks or it can't be read). */
  const blockersFor = async (status: JobStatus): Promise<GateBlocker[] | null> => {
    try {
      const blockers = gateBlockers(await fetchCompletionBlockers(job.id), job.status, status);
      return blockers.length > 0 ? blockers : null;
    } catch {
      return null; // the server re-checks the move itself
    }
  };

  const move = async (
    status: JobStatus,
    options: { reason?: string; force?: boolean } = {},
  ): Promise<void> => {
    setHeld(false);
    if ((status === 'cancelled' || status === 'no_show') && !(await releasePayments())) return;
    if (!options.force && isGatedMove(job.status, status)) {
      setChecking(true);
      const blockers = await blockersFor(status);
      setChecking(false);
      if (blockers) {
        setGate({ status, blockers });
        return;
      }
    }
    try {
      await setStatus.mutateAsync({
        status,
        ...(options.reason !== undefined ? { reason: options.reason } : {}),
        ...(options.force ? { force: true } : {}),
      });
      toast.success(`Job marked ${statusLabel('job', status).toLowerCase()}`);
      setConfirming(null);
      setCancelOpen(false);
      setReason('');
      setGate(null);
      setOverrideReason('');
    } catch (error) {
      // A gate that closed meanwhile (another device ticked an item off):
      // show what is missing instead of the raw refusal.
      if (!options.force && toAppError(error).code === '23514' && isGatedMove(job.status, status)) {
        const blockers = await blockersFor(status);
        if (blockers) {
          setGate({ status, blockers });
          return;
        }
      }
      toast.error(error);
    }
  };

  const onStep = (edge: StatusTransition) => {
    if (edge.direction === 'backward' || edge.to_status === 'no_show') {
      setConfirming(edge);
      return;
    }
    void move(edge.to_status);
  };

  const sideExit = job.status === 'cancelled' || job.status === 'no_show';

  return (
    <div className="flex flex-col gap-3">
      {sideExit && (
        <div
          role="status"
          className="border-line bg-surface-2 text-ink rounded-control border px-3 py-2 text-sm"
        >
          {job.status === 'cancelled' ? (
            <>
              Cancelled {job.cancelled_at ? formatDateTime(job.cancelled_at, timezone) : ''}
              {job.cancel_reason ? ` — ${job.cancel_reason}` : ''}
            </>
          ) : (
            'The customer did not show up.'
          )}
          {steps.some((s) => s.transition) && (
            <span className="text-muted"> Choose a step below to reinstate the job.</span>
          )}
        </div>
      )}
      <nav aria-label="Job status" aria-busy={transitions.isPending || undefined}>
        <ol className="flex flex-wrap gap-1.5">
          {steps.map((step, i) => {
            const needsSchedule = statusNeedsSchedule(step.status) && !job.scheduled_start;
            const clickable = step.transition !== null && !needsSchedule && !busy;
            const content = (
              <>
                <span
                  aria-hidden="true"
                  className={cn(
                    'flex size-5 items-center justify-center rounded-full text-[11px] font-semibold',
                    step.state === 'done' && 'bg-success-soft text-success-ink',
                    step.state === 'current' && 'bg-primary text-primary-fg',
                    step.state === 'upcoming' && 'bg-surface-3 text-muted',
                  )}
                >
                  {step.state === 'done' ? <Check className="size-3" /> : i + 1}
                </span>
                {statusLabel('job', step.status)}
              </>
            );
            const base =
              'inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-medium';
            return (
              <li key={step.status}>
                {clickable && step.transition ? (
                  <button
                    type="button"
                    onClick={() => step.transition && onStep(step.transition)}
                    className={cn(
                      base,
                      'border-line-strong bg-surface text-ink hover:border-primary hover:bg-primary-soft',
                    )}
                    aria-label={`${step.transition.direction === 'backward' ? 'Move back to' : 'Mark as'} ${statusLabel('job', step.status)}`}
                  >
                    {content}
                  </button>
                ) : (
                  <span
                    aria-current={step.state === 'current' ? 'step' : undefined}
                    aria-describedby={step.transition && needsSchedule ? scheduleHintId : undefined}
                    className={cn(
                      base,
                      step.state === 'current'
                        ? 'border-primary bg-primary-soft text-primary-ink'
                        : 'border-line text-muted',
                    )}
                  >
                    {content}
                  </span>
                )}
              </li>
            );
          })}
        </ol>
      </nav>
      {waitingForSchedule.length > 0 && (
        <p id={scheduleHintId} className="text-muted text-xs">
          Schedule the job first: it needs a date and time before it can be marked{' '}
          {waitingForSchedule.map((s) => statusLabel('job', s.status)).join(' or ')}.
        </p>
      )}
      {transitions.isError && (
        // Without the transitions no step (and no Cancel / No-show) can be
        // offered: say so and offer a retry instead of a silently dead stepper.
        <div
          role="alert"
          className="bg-danger-soft text-danger-ink rounded-control flex flex-wrap items-center gap-2 px-3 py-2 text-sm"
        >
          <p className="min-w-0 flex-1">
            Couldn’t load the status steps, so the status can’t be changed right now.{' '}
            {errorMessage(transitions.error)}
          </p>
          <Button
            size="sm"
            variant="secondary"
            loading={transitions.isFetching}
            onClick={() => void transitions.refetch()}
          >
            Try again
          </Button>
        </div>
      )}
      {(cancelEdge || noShowEdge) && (
        <div className="flex flex-wrap gap-2">
          {cancelEdge && (
            <Button
              variant="secondary"
              size="sm"
              leadingIcon={<Ban className="size-4" aria-hidden="true" />}
              onClick={() => setCancelOpen(true)}
            >
              Cancel job
            </Button>
          )}
          {noShowEdge && (
            <Button
              variant="secondary"
              size="sm"
              leadingIcon={<UserX className="size-4" aria-hidden="true" />}
              onClick={() => setConfirming(noShowEdge)}
            >
              No-show
            </Button>
          )}
        </div>
      )}

      <ConfirmDialog
        open={confirming !== null}
        onClose={() => setConfirming(null)}
        onConfirm={() => (confirming ? move(confirming.to_status) : undefined)}
        loading={busy}
        tone={confirming?.to_status === 'no_show' ? 'danger' : 'primary'}
        title={
          confirming?.to_status === 'no_show'
            ? 'Mark as no-show?'
            : `Move back to ${confirming ? statusLabel('job', confirming.to_status) : ''}?`
        }
        description={
          confirming?.to_status === 'no_show'
            ? 'The customer did not show up for this appointment. Open deposit and pay links for it stop working.'
            : 'Timestamps for the later steps are cleared.'
        }
        confirmLabel={confirming?.to_status === 'no_show' ? 'Mark no-show' : 'Move back'}
      >
        {held && confirming?.to_status === 'no_show' && <PaymentHeld />}
      </ConfirmDialog>

      <Dialog
        open={cancelOpen}
        onClose={() => {
          setCancelOpen(false);
          setHeld(false);
        }}
        title="Cancel this job?"
        description="The job leaves the calendar. Unsigned forms become void, and open deposit and pay links for it stop working. The customer isn’t messaged automatically."
        size="sm"
        dismissible={!busy}
        footer={
          <>
            <Button variant="secondary" onClick={() => setCancelOpen(false)}>
              Keep job
            </Button>
            <Button
              variant="danger"
              loading={busy}
              onClick={() => void move('cancelled', { reason })}
            >
              Cancel job
            </Button>
          </>
        }
      >
        {held && <PaymentHeld />}
        {/* set_job_status stores this as jobs.cancel_reason, which the
            customer's /booking/:token page prints in its cancelled banner. */}
        <FormField
          label="Reason for the customer"
          help="Optional. The customer sees this on their booking page — don’t include internal notes."
        >
          <Textarea
            rows={3}
            maxLength={REASON_MAX}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </FormField>
      </Dialog>

      <Dialog
        open={gate !== null}
        onClose={() => {
          if (setStatus.isPending) return;
          setGate(null);
          setOverrideReason('');
        }}
        title={
          gate?.status === 'completed'
            ? 'This job can’t be completed yet'
            : 'This job can’t be started yet'
        }
        description="Your shop requires these first."
        size="sm"
        dismissible={!setStatus.isPending}
        footer={
          <>
            <Button
              variant="secondary"
              disabled={setStatus.isPending}
              onClick={() => {
                setGate(null);
                setOverrideReason('');
              }}
            >
              {canOverride ? 'Cancel' : 'OK'}
            </Button>
            {canOverride && gate && (
              <Button
                variant="danger"
                loading={setStatus.isPending}
                onClick={() => void move(gate.status, { force: true, reason: overrideReason })}
              >
                {gate.status === 'completed' ? 'Complete anyway' : 'Start anyway'}
              </Button>
            )}
          </>
        }
      >
        <ul className="text-ink mb-3 flex list-disc flex-col gap-1.5 pl-5 text-sm">
          {gate?.blockers.map((b) => (
            <li key={b.key}>{b.text}</li>
          ))}
        </ul>
        {canOverride ? (
          <FormField
            label="Reason for the override"
            help="Optional. Saved with the job so the team knows why."
          >
            <Textarea
              rows={2}
              maxLength={REASON_MAX}
              value={overrideReason}
              onChange={(e) => setOverrideReason(e.target.value)}
            />
          </FormField>
        ) : (
          <p className="text-muted text-sm">
            Finish these first, or ask a manager to override the requirement.
          </p>
        )}
      </Dialog>
    </div>
  );
}

function PaymentHeld() {
  return (
    <p
      role="alert"
      className="bg-warning-soft text-warning-ink rounded-control mb-3 px-3 py-2 text-sm"
    >
      A card payment is in progress — wait for it to finish.
    </p>
  );
}
