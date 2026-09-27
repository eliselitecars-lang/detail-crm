import { Ban, Check, UserX } from 'lucide-react';
import { useState } from 'react';
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
import { useShop } from '@/features/shop/shopContext';
import { useSetStatus, useStatusTransitions, type JobDetail } from '../../api';
import {
  allowedTransitions,
  statusNeedsSchedule,
  statusSteps,
  type JobStatus,
  type StatusTransition,
} from '../../model';

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
  const [confirming, setConfirming] = useState<StatusTransition | null>(null);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [reason, setReason] = useState('');

  const allowed = allowedTransitions(transitions.data ?? [], job.status, role);
  const steps = statusSteps(job.status, allowed);
  const cancelEdge = allowed.find((t) => t.to_status === 'cancelled') ?? null;
  const noShowEdge = allowed.find((t) => t.to_status === 'no_show') ?? null;

  const move = async (status: JobStatus, cancelReason?: string) => {
    try {
      await setStatus.mutateAsync({
        status,
        ...(cancelReason !== undefined ? { reason: cancelReason } : {}),
      });
      toast.success(`Job marked ${statusLabel('job', status).toLowerCase()}`);
      setConfirming(null);
      setCancelOpen(false);
      setReason('');
    } catch (error) {
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
      <nav aria-label="Job status">
        <ol className="flex flex-wrap gap-1.5">
          {steps.map((step, i) => {
            const needsSchedule = statusNeedsSchedule(step.status) && !job.scheduled_start;
            const clickable = step.transition !== null && !needsSchedule && !setStatus.isPending;
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
                    title={step.transition && needsSchedule ? 'Schedule the job first' : undefined}
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
        loading={setStatus.isPending}
        tone={confirming?.to_status === 'no_show' ? 'danger' : 'primary'}
        title={
          confirming?.to_status === 'no_show'
            ? 'Mark as no-show?'
            : `Move back to ${confirming ? statusLabel('job', confirming.to_status) : ''}?`
        }
        description={
          confirming?.to_status === 'no_show'
            ? 'The customer did not show up for this appointment.'
            : 'Timestamps for the later steps are cleared.'
        }
        confirmLabel={confirming?.to_status === 'no_show' ? 'Mark no-show' : 'Move back'}
      />

      <Dialog
        open={cancelOpen}
        onClose={() => setCancelOpen(false)}
        title="Cancel this job?"
        description="The job leaves the calendar. Unsigned forms become void."
        size="sm"
        dismissible={!setStatus.isPending}
        footer={
          <>
            <Button variant="secondary" onClick={() => setCancelOpen(false)}>
              Keep job
            </Button>
            <Button
              variant="danger"
              loading={setStatus.isPending}
              onClick={() => void move('cancelled', reason)}
            >
              Cancel job
            </Button>
          </>
        }
      >
        <FormField label="Reason" help="Optional. Shown on the job's activity.">
          <Textarea
            rows={3}
            maxLength={1000}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
        </FormField>
      </Dialog>
    </div>
  );
}
