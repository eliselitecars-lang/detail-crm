import { Gift } from 'lucide-react';
import { Link } from 'react-router';
import { Badge, CopyField, ErrorState, LoadingState, QrCode, SectionCard } from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatCents, sumCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useCustomerCredits } from '@/features/invoices/api';
import { customerName } from '@/features/quotes/shared/format';
import type { CustomerRow } from '../model';
import {
  referralShareUrl,
  useReferralCode,
  useReferralCredits,
  useReferralProgram,
} from '../parityApi';

/**
 * Referral program (P-29): the customer's code and booking link (new
 * customers get the shop's referral discount), the store credit they earned
 * when a referred customer's first job was completed, and what is left of it.
 * Managers+; hidden while the program is off and nothing was earned.
 */
export function ReferralCard({ customer }: { customer: CustomerRow }) {
  const { timezone, currency, shop } = useShop();
  const program = useReferralProgram(true);
  const enabled = program.data?.enabled === true;
  const active = !customer.archived_at && !customer.merged_into_id;
  const code = useReferralCode(customer.id, enabled && active);
  const credits = useReferralCredits(customer.id, true);
  const balance = useCustomerCredits(customer.id, true);

  if (program.isPending || credits.isPending) {
    return (
      <SectionCard title="Referrals" level={2}>
        <LoadingState variant="rows" rows={2} label="Loading referrals…" />
      </SectionCard>
    );
  }
  if (program.isError || credits.isError) {
    const failed = program.isError ? program : credits;
    return (
      <SectionCard title="Referrals" level={2}>
        <ErrorState
          compact
          title="Couldn’t load referrals"
          error={failed.error}
          retrying={program.isFetching || credits.isFetching}
          onRetry={() => {
            if (program.isError) void program.refetch();
            if (credits.isError) void credits.refetch();
          }}
        />
      </SectionCard>
    );
  }
  const earned = credits.data;
  if (!enabled && earned.length === 0) return null;

  const creditLeft = sumCents((balance.data ?? []).map((c) => c.balance_cents));
  const issued = earned.filter((c) => c.status === 'issued');

  return (
    <SectionCard
      title={
        <span className="inline-flex items-center gap-2">
          <Gift className="text-muted size-4" aria-hidden="true" />
          Referrals
        </span>
      }
      level={2}
      description={
        enabled
          ? 'Friends who book with this link get your referral discount; this customer earns store credit when their first job is completed.'
          : 'The referral program is off. Earned credit can still be used.'
      }
    >
      <div className="flex flex-col gap-4">
        {enabled && active && (
          <>
            {code.isPending ? (
              <LoadingState variant="rows" rows={1} label="Getting the referral code…" />
            ) : code.isError ? (
              <ErrorState compact error={code.error} onRetry={() => void code.refetch()} />
            ) : (
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start">
                <div className="flex min-w-0 flex-1 flex-col gap-3">
                  <CopyField
                    label="Referral code"
                    value={code.data.code}
                    copiedMessage="Code copied"
                  />
                  <CopyField
                    label="Share link"
                    value={referralShareUrl(code.data, shop.slug)}
                    copiedMessage="Link copied"
                  />
                </div>
                <QrCode
                  value={referralShareUrl(code.data, shop.slug)}
                  label={`QR code for ${customerName(customer)}’s referral link`}
                  fileName={`referral-${code.data.code}`}
                  size={120}
                />
              </div>
            )}
          </>
        )}
        <div className="flex flex-wrap gap-x-6 gap-y-1 text-sm">
          <p>
            <span className="text-muted">Credit earned: </span>
            <span className="text-ink font-medium tabular-nums">
              {formatCents(sumCents(issued.map((c) => c.amount_cents)), { currency })}
            </span>
          </p>
          <p>
            <span className="text-muted">Store credit left: </span>
            <span className="text-ink font-medium tabular-nums">
              {balance.isError ? '—' : formatCents(creditLeft, { currency })}
            </span>
          </p>
        </div>
        {earned.length > 0 && (
          <ul className="divide-line divide-y text-sm" aria-label="Referred customers">
            {earned.map((credit) => (
              <li
                key={credit.id}
                className="flex flex-wrap items-center justify-between gap-2 py-2"
              >
                <span className="min-w-0">
                  {credit.referee ? (
                    <Link
                      to={`/app/customers/${credit.referee.id}`}
                      className="text-ink hover:text-primary-ink font-medium hover:underline"
                    >
                      {customerName(credit.referee)}
                    </Link>
                  ) : (
                    'A customer'
                  )}
                  <span className="text-muted"> · {formatDate(credit.created_at, timezone)}</span>
                </span>
                {credit.status === 'issued' ? (
                  <Badge tone="success">+{formatCents(credit.amount_cents, { currency })}</Badge>
                ) : (
                  <Badge tone="neutral">No reward</Badge>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </SectionCard>
  );
}
