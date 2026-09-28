import { Check, Inbox, X } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router';
import {
  Button,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  LoadingState,
  SectionCard,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { errorMessage, toAppError } from '@/lib/errors';
import { useCan } from '@/features/shop/useCan';
import {
  useApproveRequest,
  useBookingRequests,
  useDeclineRequest,
  type BookingRequest,
} from '../api';

/** Online-booking requests awaiting approval (manager+). */
export function RequestsCard({ shopId, timezone }: { shopId: string; timezone: string }) {
  const toast = useToast();
  const requests = useBookingRequests(shopId, true);
  const approve = useApproveRequest(shopId);
  const [declining, setDeclining] = useState<BookingRequest | null>(null);

  const onApprove = async (request: BookingRequest) => {
    try {
      await approve.mutateAsync(request.id);
      toast.success('Booking approved', `Job #${request.number} is on the schedule.`);
    } catch (error) {
      toast.error(toAppError(error).message);
    }
  };

  const count = requests.data?.length ?? 0;

  return (
    <SectionCard
      title="Booking requests"
      description={count > 0 ? `${count} waiting for your approval` : undefined}
      flush
      actions={
        <Link
          to="/app/jobs?status=requested"
          className="text-primary-ink text-sm font-medium hover:underline"
        >
          All requests
        </Link>
      }
    >
      {requests.isPending ? (
        <LoadingState variant="rows" rows={2} label="Loading booking requests…" />
      ) : requests.isError ? (
        <ErrorState compact error={requests.error} onRetry={() => void requests.refetch()} />
      ) : requests.data.length === 0 ? (
        <EmptyState
          compact
          icon={<Inbox aria-hidden="true" />}
          title="No requests waiting"
          description="New online bookings that need approval appear here."
        />
      ) : (
        <ul className="divide-line divide-y">
          {requests.data.map((request) => {
            const name = request.customerName ?? 'Customer';
            const approving = approve.isPending && approve.variables === request.id;
            return (
              <li
                key={request.id}
                className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:justify-between sm:px-5"
              >
                <div className="min-w-0">
                  <Link
                    to={`/app/jobs/${request.id}`}
                    className="text-ink text-sm font-medium break-words hover:underline"
                  >
                    {name} <span className="text-muted font-normal">· #{request.number}</span>
                  </Link>
                  <p className="text-muted text-xs">
                    {request.scheduled_start
                      ? formatDateTime(request.scheduled_start, timezone)
                      : 'No time picked yet'}
                    {request.location_type === 'mobile' ? ' · Mobile' : ''}
                  </p>
                </div>
                <div className="flex shrink-0 gap-2">
                  <Button
                    size="sm"
                    variant="secondary"
                    leadingIcon={<X className="size-3.5" aria-hidden="true" />}
                    aria-label={`Decline booking from ${name}`}
                    disabled={approving}
                    onClick={() => setDeclining(request)}
                  >
                    Decline
                  </Button>
                  <Button
                    size="sm"
                    leadingIcon={<Check className="size-3.5" aria-hidden="true" />}
                    aria-label={`Approve booking from ${name}`}
                    loading={approving}
                    disabled={!request.scheduled_start}
                    title={
                      request.scheduled_start ? undefined : 'Open the job to pick a time first'
                    }
                    onClick={() => void onApprove(request)}
                  >
                    Approve
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
      {declining && (
        <DeclineDialog shopId={shopId} request={declining} onClose={() => setDeclining(null)} />
      )}
    </SectionCard>
  );
}

function DeclineDialog({
  shopId,
  request,
  onClose,
}: {
  shopId: string;
  request: BookingRequest;
  onClose: () => void;
}) {
  const toast = useToast();
  const decline = useDeclineRequest(shopId);
  const canCollect = useCan('payments.collect');
  const [reason, setReason] = useState('');
  const tooLong = reason.length > 1000;

  const submit = async () => {
    if (tooLong) return;
    try {
      const { recorded } = await decline.mutateAsync({
        jobId: request.id,
        reason,
        releasePayments: canCollect,
      });
      if (recorded > 0) {
        toast.info(
          'Booking declined',
          `Job #${request.number} was cancelled. ${
            recorded === 1 ? 'A card payment had' : 'Card payments had'
          } already gone through — it’s recorded on the job, so refund it if needed.`,
        );
      } else {
        toast.success('Booking declined', `Job #${request.number} was cancelled.`);
      }
      onClose();
    } catch (error) {
      // Already approved/cancelled elsewhere: nothing to decline any more.
      if (toAppError(error).kind === 'conflict') {
        toast.error(toAppError(error).message);
        onClose();
      }
      // Other errors are shown in the dialog below.
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!decline.isPending}
      role="alertdialog"
      size="sm"
      title="Decline this booking?"
      description={`${request.customerName ?? 'The customer'}’s request #${request.number} will be cancelled${
        canCollect ? ' and any open deposit link closed, so nobody pays for it' : ''
      }.`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={decline.isPending}>
            Keep request
          </Button>
          <Button
            variant="danger"
            loading={decline.isPending}
            disabled={tooLong}
            onClick={() => void submit()}
          >
            Decline booking
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        {/* jobs.cancel_reason is customer-facing: /booking/:token prints it in
            the "This booking was cancelled" banner (booking_public_json). */}
        <FormField
          label="Reason for the customer"
          help="Optional. The customer sees this on their booking page — don’t include internal notes."
          error={tooLong ? 'Keep the reason under 1,000 characters.' : undefined}
        >
          <Textarea
            rows={3}
            value={reason}
            placeholder="e.g. We’re fully booked that day"
            onChange={(e) => setReason(e.target.value)}
          />
        </FormField>
        {/* Nothing is sent on decline: no cancellation template exists, the
            status trigger ignores 'cancelled', and appointment templates are
            refused for cancelled jobs (messaging appointment_closed). */}
        <p className="bg-primary-soft text-primary-ink rounded-control px-3 py-2 text-sm">
          The customer isn’t messaged automatically. Let them know from the inbox.
        </p>
        {decline.isError && (
          <p role="alert" className="text-danger-ink text-sm">
            {errorMessage(decline.error)}
          </p>
        )}
      </div>
    </Dialog>
  );
}
