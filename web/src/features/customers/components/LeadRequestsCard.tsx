import { Inbox } from 'lucide-react';
import { Link } from 'react-router';
import { Badge, ErrorState, KeyValueList, LoadingState, SectionCard } from '@/components/ui';
import { CustomFieldValues } from '@/components/customFields';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { formatDateTime } from '@/lib/dates';
import {
  LEAD_REQUESTS_LIMIT,
  leadVehicleText,
  useCustomerFields,
  useCustomerLeadRequests,
  type LeadRequest,
} from '../parityApi';

/**
 * What this customer asked for on the shop's lead forms (P-9): the message,
 * the vehicle they described and their answers. A lead form never changes an
 * existing customer's record, so this is the only place staff see the
 * request. Managers+ (the server's rule for lead_submissions); nothing is
 * shown for a customer who never sent a form.
 */
export function LeadRequestsCard({ customerId }: { customerId: string }) {
  const canSee = useCan('customers.manage');
  const requests = useCustomerLeadRequests(customerId, canSee);
  if (!canSee) return null;

  if (requests.isPending) {
    return (
      <SectionCard title="Web form requests" level={2} className="lg:col-span-2">
        <LoadingState variant="rows" rows={2} label="Loading requests…" />
      </SectionCard>
    );
  }
  if (requests.isError) {
    return (
      <SectionCard title="Web form requests" level={2} className="lg:col-span-2">
        <ErrorState
          compact
          error={requests.error}
          onRetry={() => void requests.refetch()}
          retrying={requests.isRefetching}
        />
      </SectionCard>
    );
  }
  const { requests: rows, total } = requests.data;
  if (rows.length === 0) return null;

  return (
    <SectionCard
      title="Web form requests"
      description={
        total > rows.length
          ? `The latest ${rows.length} of ${total} requests sent from your lead forms.`
          : 'Sent from your lead forms. Their details are kept here as they were sent.'
      }
      level={2}
      className="lg:col-span-2"
      flush
    >
      <ul className="divide-line divide-y" aria-label="Web form requests">
        {rows.map((request) => (
          <LeadRequestItem key={request.id} request={request} />
        ))}
      </ul>
      {total > LEAD_REQUESTS_LIMIT && (
        <p className="text-muted border-line border-t px-4 py-3 text-sm sm:px-5">
          Older requests aren’t shown.
        </p>
      )}
    </SectionCard>
  );
}

function LeadRequestItem({ request }: { request: LeadRequest }) {
  const { timezone } = useShop();
  const fields = useCustomerFields();
  const vehicle = leadVehicleText(request.vehicle);
  const hasAnswers = Object.keys(request.answers).length > 0;

  return (
    <li className="flex flex-col gap-3 px-4 py-4 sm:px-5">
      <div className="flex flex-wrap items-center gap-2">
        <Inbox className="text-muted size-4 shrink-0" aria-hidden="true" />
        <span className="text-ink text-sm font-medium">
          {request.form_name ?? 'A deleted lead form'}
        </span>
        <span className="text-muted text-sm">{formatDateTime(request.created_at, timezone)}</span>
        {request.matched_existing && <Badge>Existing customer</Badge>}
      </div>
      {request.message ? (
        <p className="text-ink bg-surface-2 rounded-control px-3 py-2 text-sm break-words whitespace-pre-wrap">
          {request.message}
        </p>
      ) : (
        <p className="text-muted text-sm">No message.</p>
      )}
      {vehicle && (
        <KeyValueList items={[{ key: 'vehicle', label: 'Vehicle described', value: vehicle }]} />
      )}
      {hasAnswers &&
        (fields.isError ? (
          <ErrorState compact error={fields.error} onRetry={() => void fields.refetch()} />
        ) : (
          <CustomFieldValues fields={fields.data ?? []} data={request.answers} />
        ))}
      {request.matched_existing && vehicle && (
        <p className="text-muted text-sm">
          The form matched this customer, so nothing on their record was changed and the vehicle
          wasn’t added.{' '}
          <Link to="?tab=vehicles" className="text-primary-ink hover:underline">
            Open vehicles
          </Link>
        </p>
      )}
    </li>
  );
}
