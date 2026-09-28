import { Link2 } from 'lucide-react';
import { Badge, KeyValueList, SectionCard } from '@/components/ui';
import { UnappliedPaymentsCard } from '@/features/payments/components/UnappliedPaymentsCard';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { formatDate } from '@/lib/dates';
import { formatPhone, phoneHref } from '@/lib/phone';
import { CustomDataCard } from './CustomDataCard';
import { CustomerSummaryCard } from './CustomerSummaryCard';
import { LeadRequestsCard } from './LeadRequestsCard';
import { ReferralCard } from './ReferralCard';
import { UnbilledJobsCard } from './UnbilledJobsCard';
import { customerAddress, LIFECYCLE_LABELS, SOURCE_LABELS, type CustomerRow } from '../model';

function optInText(optedIn: boolean, optedOutAt: string | null, timezone: string): string {
  if (optedOutAt) return `Opted out ${formatDate(optedOutAt, timezone)}`;
  return optedIn ? 'Opted in' : 'Not opted in';
}

/** Totals (manager+), contact, tags, notes, lifecycle and portal status. */
export function OverviewTab({ customer }: { customer: CustomerRow }) {
  const { timezone } = useShop();
  // customer_summary is owner/admin/manager only (money); technicians skip it.
  const canSeeTotals = useCan('payments.view');
  const canInvoice = useCan('invoices.manage');
  const canReferrals = useCan('giftCards.view');
  const address = customerAddress(customer);
  const tel = phoneHref(customer.phone);

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
      {canSeeTotals && <CustomerSummaryCard customerId={customer.id} />}
      {canSeeTotals && <UnappliedPaymentsCard customerId={customer.id} />}
      {canInvoice && !customer.merged_into_id && <UnbilledJobsCard customerId={customer.id} />}
      <LeadRequestsCard customerId={customer.id} />
      <SectionCard title="Contact" level={2}>
        <KeyValueList
          items={[
            {
              key: 'phone',
              label: 'Mobile',
              value:
                customer.phone && tel ? (
                  <a href={tel} className="text-primary-ink tabular hover:underline">
                    {formatPhone(customer.phone)}
                  </a>
                ) : null,
            },
            {
              key: 'email',
              label: 'Email',
              value: customer.email ? (
                <a href={`mailto:${customer.email}`} className="text-primary-ink hover:underline">
                  {customer.email}
                </a>
              ) : null,
            },
            { key: 'company', label: 'Company', value: customer.company },
            { key: 'address', label: 'Address', value: address || null },
            {
              key: 'sms',
              label: 'Text messages',
              value: optInText(customer.sms_opt_in, customer.sms_opted_out_at, timezone),
            },
            {
              key: 'emailOpt',
              label: 'Marketing email',
              value: optInText(customer.email_opt_in, customer.email_opted_out_at, timezone),
            },
          ]}
        />
      </SectionCard>

      <SectionCard title="Details" level={2}>
        <KeyValueList
          items={[
            {
              key: 'lifecycle',
              label: 'Lifecycle',
              value: (
                <Badge tone={customer.lifecycle === 'lead' ? 'warning' : 'neutral'}>
                  {LIFECYCLE_LABELS[customer.lifecycle]}
                </Badge>
              ),
            },
            { key: 'source', label: 'Source', value: SOURCE_LABELS[customer.source] },
            {
              key: 'portal',
              label: 'Client portal',
              value: customer.portal_user_id ? (
                <Badge tone="success">
                  <Link2 className="size-3" aria-hidden="true" />
                  Account linked
                </Badge>
              ) : (
                'Not linked'
              ),
            },
            {
              key: 'added',
              label: 'Customer since',
              value: formatDate(customer.created_at, timezone),
            },
            {
              key: 'tags',
              label: 'Tags',
              value:
                customer.tags.length > 0 ? (
                  <span className="inline-flex flex-wrap justify-end gap-1">
                    {customer.tags.map((t) => (
                      <Badge key={t}>{t}</Badge>
                    ))}
                  </span>
                ) : null,
            },
          ]}
        />
      </SectionCard>

      {canReferrals && <ReferralCard customer={customer} />}

      <CustomDataCard customer={customer} />

      <SectionCard title="Notes" level={2} className="lg:col-span-2">
        {customer.notes ? (
          <p className="text-ink text-sm break-words whitespace-pre-wrap">{customer.notes}</p>
        ) : (
          <p className="text-muted text-sm">No notes yet.</p>
        )}
      </SectionCard>
    </div>
  );
}
