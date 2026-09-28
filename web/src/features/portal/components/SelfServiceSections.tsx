import { ClipboardCheck, CreditCard, FileText, Gift, Repeat } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import { Link } from 'react-router';
import {
  Badge,
  Button,
  ConfirmDialog,
  CopyField,
  ErrorState,
  SectionCard,
  StatusBadge,
  formatBytes,
  useToast,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { formatBps, formatCents } from '@/lib/money';
import { documentTypeLabel, fetchPortalDocumentUrl } from '@/features/job-report/media';
import { navigation } from '@/features/public-docs/shared/checkout';
import {
  useBillingPortal,
  useCancelMembership,
  usePortalDocuments,
  usePortalMemberships,
  usePortalReferrals,
  usePortalReports,
  type PortalMembership,
  type PortalOverview,
  type PortalShop,
} from '../api';

type ShopLookup = (slug: string) => PortalShop | undefined;

/** The overview's shop by slug (rows name their shop by slug; names are not unique). */
function lookup(data: PortalOverview): ShopLookup {
  const bySlug = new Map(data.shops.map((s) => [s.slug, s]));
  return (slug) => bySlug.get(slug);
}

function RowIcon({ children }: { children: ReactNode }) {
  return (
    <span className="bg-surface-2 text-muted flex size-9 shrink-0 items-center justify-center rounded-full [&_svg]:size-4">
      {children}
    </span>
  );
}

function every(m: Pick<PortalMembership, 'interval' | 'interval_count'>): string {
  return m.interval_count === 1 ? m.interval : `${m.interval_count} ${m.interval}s`;
}

// ---------------------------------------------------------------- memberships

/**
 * Memberships with self-service (P-23): cancel at the end of the paid period
 * and Stripe's billing page (update the card, receipts). Details the list
 * RPC doesn't carry (included services, discount, vehicle) come from the
 * overview when the plan matches.
 */
export function MembershipsSection({ userId, data }: { userId: string; data: PortalOverview }) {
  const memberships = usePortalMemberships(userId, true);
  const shopOf = lookup(data);
  const multiShop = data.shops.length > 1;
  const toast = useToast();
  const cancel = useCancelMembership(userId);
  const billing = useBillingPortal();
  const [cancelling, setCancelling] = useState<PortalMembership | null>(null);

  if (memberships.isPending) return null;
  if (memberships.isError) {
    return (
      <SectionCard title="Memberships">
        <ErrorState
          compact
          error={memberships.error}
          title="Couldn’t load your memberships"
          onRetry={() => void memberships.refetch()}
          retrying={memberships.isFetching}
        />
      </SectionCard>
    );
  }
  const rows = memberships.data;
  if (rows.length === 0) return null;

  return (
    <>
      <SectionCard title="Memberships" flush>
        <ul aria-label="Memberships" className="divide-line divide-y px-4 sm:px-5">
          {rows.map((m) => {
            const shop = shopOf(m.shop_slug);
            const currency = shop?.currency ?? 'usd';
            const extra = data.memberships.find(
              (o) => o.shop_slug === m.shop_slug && o.plan_name === m.plan_name,
            );
            const uses =
              m.uses_per_period !== null && m.uses_this_period !== null
                ? `${m.uses_this_period} of ${m.uses_per_period} visits used this period`
                : null;
            return (
              <li key={m.id} className="flex flex-col gap-2 py-3">
                <div className="flex items-start gap-3">
                  <RowIcon>
                    <Repeat aria-hidden="true" />
                  </RowIcon>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="text-ink text-sm font-semibold">{m.plan_name}</p>
                      <StatusBadge kind="membership" status={m.status} />
                      {m.cancel_at_period_end && <Badge tone="warning">Ends this period</Badge>}
                    </div>
                    <p className="text-muted text-xs">
                      {[
                        multiShop ? m.shop_name : null,
                        extra?.vehicle,
                        extra && extra.included_services.length > 0
                          ? `Includes ${extra.included_services.join(', ')}`
                          : null,
                        extra?.discount_bps
                          ? `${formatBps(extra.discount_bps)} off other services`
                          : null,
                        uses,
                        m.current_period_end && shop
                          ? `${m.cancel_at_period_end ? 'Ends' : 'Renews'} ${formatDate(m.current_period_end, shop.timezone)}`
                          : null,
                      ]
                        .filter(Boolean)
                        .join(' · ')}
                    </p>
                  </div>
                  <p className="text-ink shrink-0 text-sm font-medium tabular-nums">
                    {formatCents(m.price_cents, { currency })}
                    <span className="text-muted text-xs font-normal"> / {every(m)}</span>
                  </p>
                </div>
                {(m.status === 'active' || m.status === 'past_due') && (
                  <div className="flex flex-wrap gap-2 pl-12">
                    <Button
                      size="sm"
                      variant={m.status === 'past_due' ? 'money' : 'secondary'}
                      leadingIcon={<CreditCard className="size-4" aria-hidden="true" />}
                      loading={billing.isPending && billing.variables === m.id}
                      onClick={() =>
                        billing.mutate(m.id, { onError: (error) => toast.error(error) })
                      }
                    >
                      {m.status === 'past_due' ? 'Update card' : 'Card & billing history'}
                    </Button>
                    {m.can_cancel && (
                      <Button size="sm" variant="ghost" onClick={() => setCancelling(m)}>
                        Cancel membership
                      </Button>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      </SectionCard>
      <ConfirmDialog
        open={cancelling !== null}
        onClose={() => setCancelling(null)}
        tone="danger"
        loading={cancel.isPending}
        title={`Cancel ${cancelling?.plan_name ?? 'membership'}?`}
        description={
          cancelling?.current_period_end
            ? `It stays active until ${formatDate(
                cancelling.current_period_end,
                shopOf(cancelling.shop_slug)?.timezone ?? 'UTC',
              )} and won’t renew. You won’t be charged again.`
            : 'It stays active until the end of the period you paid for and won’t renew.'
        }
        confirmLabel="Cancel at period end"
        cancelLabel="Keep membership"
        onConfirm={async () => {
          if (!cancelling) return;
          try {
            await cancel.mutateAsync(cancelling.id);
            toast.success('Your membership will end at the close of this period');
          } catch (error) {
            toast.error(error);
          } finally {
            setCancelling(null);
          }
        }}
      />
    </>
  );
}

// ---------------------------------------------------------------- documents

export function DocumentsSection({ userId, data }: { userId: string; data: PortalOverview }) {
  const documents = usePortalDocuments(userId, true);
  const multiShop = data.shops.length > 1;
  const [opening, setOpening] = useState<string | null>(null);
  const [openError, setOpenError] = useState<unknown>(null);

  if (documents.isPending) return null;
  if (documents.isError) {
    return (
      <SectionCard title="Documents">
        <ErrorState
          compact
          error={documents.error}
          title="Couldn’t load your documents"
          onRetry={() => void documents.refetch()}
          retrying={documents.isFetching}
        />
      </SectionCard>
    );
  }
  if (documents.data.length === 0) return null;

  // Open a tab while still inside the click (popup blockers), then point it
  // at the short-lived signed link once the server has made it.
  const open = async (id: string) => {
    setOpening(id);
    setOpenError(null);
    const tab = window.open('', '_blank');
    if (tab) tab.opener = null;
    try {
      const url = await fetchPortalDocumentUrl(id);
      if (tab) tab.location.href = url;
      else navigation.assign(url);
    } catch (error) {
      tab?.close();
      setOpenError(error);
    } finally {
      setOpening(null);
    }
  };

  return (
    <SectionCard title="Documents" flush>
      {openError !== null && (
        <p role="alert" className="text-danger-ink border-line border-b px-4 py-2 text-sm sm:px-5">
          {errorMessage(openError)}
        </p>
      )}
      <ul aria-label="Documents" className="divide-line divide-y px-4 sm:px-5">
        {documents.data.map((doc) => {
          return (
            <li key={doc.id} className="flex items-center gap-3 py-3">
              <RowIcon>
                <FileText aria-hidden="true" />
              </RowIcon>
              <div className="min-w-0 flex-1">
                <p className="text-ink truncate text-sm font-semibold">{doc.file_name}</p>
                <p className="text-muted text-xs">
                  {[
                    multiShop ? doc.shop_name : null,
                    doc.job_number !== null ? `Appointment #${doc.job_number}` : null,
                    documentTypeLabel(doc.content_type),
                    doc.size_bytes !== null ? formatBytes(doc.size_bytes) : null,
                    formatDate(doc.created_at, doc.timezone),
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              </div>
              <Button
                size="sm"
                variant="secondary"
                loading={opening === doc.id}
                onClick={() => void open(doc.id)}
              >
                Open<span className="sr-only"> {doc.file_name} (new tab)</span>
              </Button>
            </li>
          );
        })}
      </ul>
    </SectionCard>
  );
}

// ---------------------------------------------------------------- job reports

export function JobReportsSection({ userId, data }: { userId: string; data: PortalOverview }) {
  const reports = usePortalReports(userId, true);
  const multiShop = data.shops.length > 1;
  if (reports.isPending) return null;
  if (reports.isError) {
    return (
      <SectionCard title="Job reports">
        <ErrorState
          compact
          error={reports.error}
          title="Couldn’t load your job reports"
          onRetry={() => void reports.refetch()}
          retrying={reports.isFetching}
        />
      </SectionCard>
    );
  }
  if (reports.data.length === 0) return null;
  return (
    <SectionCard
      title="Job reports"
      description="Photos and inspection results from your visits."
      flush
    >
      <ul aria-label="Job reports" className="divide-line divide-y px-4 sm:px-5">
        {reports.data.map((r) => {
          const when = r.completed_at ?? r.published_at;
          return (
            <li key={r.report_path}>
              <Link
                to={r.report_path}
                className="hover:bg-surface-2 focus-visible:outline-primary -mx-2 flex items-center gap-3 rounded-lg px-2 py-3 focus-visible:outline-2"
              >
                <RowIcon>
                  <ClipboardCheck aria-hidden="true" />
                </RowIcon>
                <div className="min-w-0 flex-1">
                  <p className="text-ink text-sm font-semibold">Appointment #{r.job_number}</p>
                  <p className="text-muted text-xs">
                    {[multiShop ? r.shop_name : null, when ? formatDate(when, r.timezone) : null]
                      .filter(Boolean)
                      .join(' · ') || 'View the report'}
                  </p>
                </div>
              </Link>
            </li>
          );
        })}
      </ul>
    </SectionCard>
  );
}

// ---------------------------------------------------------------- referrals

/** The client's referral code per shop (portal_referrals creates it on first view). */
export function ReferralsSection({ userId, data }: { userId: string; data: PortalOverview }) {
  const referrals = usePortalReferrals(userId, true);
  const multiShop = data.shops.length > 1;
  if (referrals.isPending) return null;
  if (referrals.isError) {
    return (
      <SectionCard title="Refer a friend">
        <ErrorState
          compact
          error={referrals.error}
          title="Couldn’t load your referral code"
          onRetry={() => void referrals.refetch()}
          retrying={referrals.isFetching}
        />
      </SectionCard>
    );
  }
  if (referrals.data.length === 0) return null;
  return (
    <SectionCard
      title="Refer a friend"
      description="Share your code: your friend saves on their first visit, and you earn store credit when it’s done."
    >
      <div className="flex flex-col gap-5">
        {referrals.data.map((r) => {
          const { currency } = r;
          return (
            <div key={`${r.shop_slug}-${r.code}`} className="flex flex-col gap-3">
              {(multiShop || referrals.data.length > 1) && (
                <p className="text-ink flex items-center gap-2 text-sm font-semibold">
                  <Gift className="text-muted size-4" aria-hidden="true" />
                  {r.shop_name}
                </p>
              )}
              <CopyField label="Your code" value={r.code} copiedMessage="Code copied" />
              {r.share_url && (
                <CopyField label="Your link" value={r.share_url} copiedMessage="Link copied" />
              )}
              <p className="text-muted text-sm">
                Earned so far: {formatCents(r.credits_earned_cents, { currency })} · Credit you can
                use now: {formatCents(r.credit_balance_cents, { currency })}
              </p>
            </div>
          );
        })}
      </div>
    </SectionCard>
  );
}
