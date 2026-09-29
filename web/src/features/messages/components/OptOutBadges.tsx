import { Badge } from '@/components/ui';
import { formatDate } from '@/lib/dates';
import type { ThreadCustomer } from '../model';

/** Opt-out / opt-in state for a customer (messages are blocked server-side after an opt-out). */
export function OptOutBadges({
  customer,
  timeZone,
}: {
  customer: Pick<
    ThreadCustomer,
    'sms_opted_out_at' | 'email_opted_out_at' | 'sms_opt_in' | 'email_opt_in' | 'archived_at'
  >;
  timeZone: string;
}) {
  return (
    <span className="flex flex-wrap gap-1.5">
      {customer.sms_opted_out_at && (
        <Badge tone="danger">
          Texts opted out {formatDate(customer.sms_opted_out_at, timeZone)}
        </Badge>
      )}
      {customer.email_opted_out_at && (
        <Badge tone="danger">
          Opted out of all email {formatDate(customer.email_opted_out_at, timeZone)}
        </Badge>
      )}
      {!customer.sms_opted_out_at && customer.sms_opt_in && (
        <Badge tone="success">Texts opted in</Badge>
      )}
      {!customer.email_opted_out_at && customer.email_opt_in && (
        <Badge tone="success">Email opted in</Badge>
      )}
      {customer.archived_at && <Badge tone="neutral">Archived</Badge>}
    </span>
  );
}
