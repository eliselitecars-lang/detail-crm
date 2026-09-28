import { Copy, FileText, Pencil, Send } from 'lucide-react';
import { useState } from 'react';
import { Link, useNavigate } from 'react-router';
import {
  Button,
  buttonClasses,
  CopyField,
  Dialog,
  ErrorState,
  FormField,
  KeyValueList,
  LoadingState,
  MoneyInput,
  SectionCard,
  StatusBadge,
  Switch,
  useToast,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useUpdateJob, type JobDetail } from '../../api';
import { copyText } from '@/features/quotes/shared/format';
import {
  useCreateInvoice,
  useDepositFollowup,
  useJobBookingLink,
  usePaymentSummary,
  useSendJobTemplate,
  useSetDepositFollowupsPaused,
} from '../../fieldApi';
import { describeFollowup } from '../../model';

/**
 * Deposit and invoice panel. Every amount is read from job_payment_summary
 * (server): deposit paid/due, received, tips, balance.
 */
export function MoneyCard({ job }: { job: JobDetail }) {
  const { currency } = useShop();
  const canCollect = useCan('invoices.viewAssigned');
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const navigate = useNavigate();
  const summary = usePaymentSummary(job.id, canCollect);
  const createInvoice = useCreateInvoice(job.id);
  const [editingDeposit, setEditingDeposit] = useState(false);
  const money = (cents: number | null | undefined) => formatCents(cents, { currency });

  if (!canCollect) return null;

  const s = summary.data;
  const hasInvoice = s?.invoice_id && s.invoice_status && s.invoice_status !== 'void';

  const onCreateInvoice = async () => {
    try {
      const id = await createInvoice.mutateAsync();
      toast.success('Invoice created');
      await navigate(`/app/invoices/${id}`);
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard
      title="Payments"
      level={3}
      actions={
        canManage ? (
          <Button
            size="sm"
            variant="ghost"
            leadingIcon={<Pencil className="size-4" aria-hidden="true" />}
            onClick={() => setEditingDeposit(true)}
          >
            Deposit
          </Button>
        ) : undefined
      }
    >
      {summary.isPending ? (
        <LoadingState label="Loading payments…" />
      ) : summary.isError ? (
        <ErrorState compact error={summary.error} onRetry={() => void summary.refetch()} />
      ) : (
        <div className="flex flex-col gap-3">
          <KeyValueList
            items={[
              {
                key: 'deposit',
                label: 'Deposit required',
                value: money(s?.deposit_required_cents ?? job.deposit_required_cents),
              },
              ...((s?.deposit_required_cents ?? 0) > 0
                ? [
                    { key: 'dpaid', label: 'Deposit paid', value: money(s?.deposit_paid_cents) },
                    {
                      key: 'ddue',
                      label: 'Deposit due',
                      value: money(s?.deposit_due_cents),
                      emphasis: (s?.deposit_due_cents ?? 0) > 0,
                    },
                  ]
                : []),
              { key: 'paid', label: 'Received', value: money(s?.paid_cents) },
              ...((s?.pending_cents ?? 0) > 0
                ? [{ key: 'pending', label: 'Processing', value: money(s?.pending_cents) }]
                : []),
              ...((s?.tip_cents ?? 0) > 0
                ? [{ key: 'tips', label: 'Tips', value: money(s?.tip_cents) }]
                : []),
              ...((s?.refunded_cents ?? 0) > 0
                ? [{ key: 'refunded', label: 'Refunded', value: money(s?.refunded_cents) }]
                : []),
              {
                key: 'balance',
                label: 'Balance',
                value: (
                  <span className="text-money-ink font-semibold">{money(s?.balance_cents)}</span>
                ),
                emphasis: true,
              },
            ]}
          />
          {canManage && (s?.deposit_due_cents ?? 0) > 0 && !DEPOSIT_CLOSED.has(job.status) && (
            <DepositRequest job={job} />
          )}
          {canManage && (s?.deposit_due_cents ?? 0) > 0 && <DepositFollowups jobId={job.id} />}
          {hasInvoice && s.invoice_id ? (
            <div className="border-line flex flex-wrap items-center justify-between gap-2 border-t pt-3">
              <span className="flex items-center gap-2 text-sm">
                <FileText className="text-muted size-4" aria-hidden="true" />
                Invoice #{s.invoice_number}
                {s.invoice_status && <StatusBadge kind="invoice" status={s.invoice_status} />}
              </span>
              <Link
                to={`/app/invoices/${s.invoice_id}`}
                className={buttonClasses({ variant: 'money', size: 'sm' })}
              >
                Open invoice
              </Link>
            </div>
          ) : (
            <Button
              variant="money"
              loading={createInvoice.isPending}
              leadingIcon={<FileText className="size-4" aria-hidden="true" />}
              onClick={() => void onCreateInvoice()}
            >
              Create invoice
            </Button>
          )}
        </div>
      )}
      {editingDeposit && <DepositDialog job={job} onClose={() => setEditingDeposit(false)} />}
    </SectionCard>
  );
}

/** Statuses where the booking page no longer takes a deposit. */
const DEPOSIT_CLOSED: ReadonlySet<JobDetail['status']> = new Set([
  'completed',
  'cancelled',
  'no_show',
]);

/**
 * Asking for a deposit that is due (managers+): the customer pays it on the
 * booking page (/booking/<token>, job_booking_token). Staff copy the link or
 * send the shop's "Booking confirmed" message, which carries it
 * ({{booking_link}}); the server re-checks the role and the customer's
 * consent for the channel.
 */
function DepositRequest({ job }: { job: JobDetail }) {
  const toast = useToast();
  const link = useJobBookingLink(job.id);
  const send = useSendJobTemplate(job.id);
  const [manualCopy, setManualCopy] = useState<string | null>(null);
  const channel: 'sms' | 'email' = job.customer?.phone ? 'sms' : 'email';

  const onCopy = async () => {
    try {
      const url = await link.mutateAsync();
      if (await copyText(url)) {
        setManualCopy(null);
        toast.success('Booking link copied', 'The customer can pay the deposit there.');
      } else {
        setManualCopy(url);
      }
    } catch (error) {
      toast.error(error);
    }
  };

  const onSend = async () => {
    try {
      const result = await send.mutateAsync({ templateKey: 'booking_confirmed', channel });
      if (result.status === 'failed') {
        toast.error('The message could not be delivered', result.error ?? undefined);
      } else {
        toast.success(channel === 'sms' ? 'Booking link texted' : 'Booking link emailed');
      }
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <div className="bg-surface-2 rounded-control flex flex-col gap-2 px-3 py-2 text-sm">
      <p className="text-ink">
        The customer pays the deposit on their booking page. Send or copy the link.
      </p>
      <div className="flex flex-wrap gap-2">
        <Button
          size="sm"
          variant="secondary"
          loading={send.isPending}
          leadingIcon={<Send className="size-4" aria-hidden="true" />}
          onClick={() => void onSend()}
        >
          {channel === 'sms' ? 'Text booking link' : 'Email booking link'}
        </Button>
        <Button
          size="sm"
          variant="ghost"
          loading={link.isPending}
          leadingIcon={<Copy className="size-4" aria-hidden="true" />}
          onClick={() => void onCopy()}
        >
          Copy booking link
        </Button>
      </div>
      {manualCopy && <CopyField label="Booking link" value={manualCopy} />}
    </div>
  );
}

/** Automatic deposit reminders (P-3): status + pause, managers+. */
function DepositFollowups({ jobId }: { jobId: string }) {
  const { timezone } = useShop();
  const toast = useToast();
  const canSettings = useCan('settings.view');
  const status = useDepositFollowup(jobId, true);
  const pause = useSetDepositFollowupsPaused(jobId);
  if (status.isPending) return null;
  if (status.isError) {
    return <ErrorState compact error={status.error} onRetry={() => void status.refetch()} />;
  }
  const s = status.data;
  return (
    <div className="bg-surface-2 rounded-control flex flex-col gap-2 px-3 py-2 text-sm">
      <p className="text-ink" role="status">
        {describeFollowup(s, timezone)}{' '}
        {!s.enabled && canSettings && (
          <Link to="/app/settings/followups" className="text-primary-ink underline">
            Set up reminders
          </Link>
        )}
      </p>
      {s.enabled && (
        <Switch
          label="Pause reminders for this job"
          checked={s.paused}
          disabled={pause.isPending}
          onCheckedChange={(paused) =>
            pause
              .mutateAsync(paused)
              .then(() =>
                toast.success(paused ? 'Deposit reminders paused' : 'Deposit reminders on'),
              )
              .catch((error: unknown) => toast.error(error))
          }
        />
      )}
    </div>
  );
}

function DepositDialog({ job, onClose }: { job: JobDetail; onClose: () => void }) {
  const toast = useToast();
  const update = useUpdateJob(job.id);
  const [value, setValue] = useState<number | null>(job.deposit_required_cents);
  const save = async () => {
    try {
      await update.mutateAsync({ deposit_required_cents: value ?? 0 });
      toast.success('Deposit saved');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };
  return (
    <Dialog
      open
      onClose={onClose}
      title="Deposit required"
      description="Set to 0 when no deposit is needed."
      size="sm"
      dismissible={!update.isPending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={update.isPending}>
            Cancel
          </Button>
          <Button variant="money" loading={update.isPending} onClick={() => void save()}>
            Save
          </Button>
        </>
      }
    >
      <FormField label="Deposit">
        <MoneyInput value={value} onChange={setValue} />
      </FormField>
    </Dialog>
  );
}
