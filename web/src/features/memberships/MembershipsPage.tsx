import { BadgePercent, MoreHorizontal, Plus, Users } from 'lucide-react';
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import {
  Badge,
  Button,
  Card,
  CopyField,
  DropdownMenu,
  EmptyState,
  ErrorState,
  FormField,
  LoadingState,
  PageHeader,
  Pagination,
  QrCode,
  SectionCard,
  Select,
  StatusBadge,
  statusLabel,
  Switch,
  Table,
  Tabs,
  useToast,
  type Column,
  type DropdownMenuEntry,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatBps, formatCents } from '@/lib/money';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import { customerName, vehicleLabel } from '@/features/quotes/shared/format';
import {
  billingLabel,
  MEMBERSHIP_STATUSES,
  SUBSCRIBER_PAGE_SIZE,
  usageText,
  useArchivePlan,
  useMembershipUsage,
  usePlans,
  useSubscribers,
  type MembershipStatus,
  type PlanRow,
  type SubscriberRow,
} from './api';
import { CancelMembershipDialog } from './components/CancelMembershipDialog';
import { CheckoutLinkDialog, type CheckoutTarget } from './components/CheckoutLinkDialog';
import { NewMembershipDialog } from './components/NewMembershipDialog';
import { PlanDialog } from './components/PlanDialog';

type Tab = 'subscribers' | 'plans';

export default function MembershipsPage() {
  const canManage = useCan('memberships.manage');
  const [params, setParams] = useSearchParams();
  const tab: Tab = params.get('tab') === 'plans' ? 'plans' : 'subscribers';
  const [newOpen, setNewOpen] = useState(false);
  const [checkout, setCheckout] = useState<CheckoutTarget | null>(null);
  const [planDialog, setPlanDialog] = useState<{ plan: PlanRow | null } | null>(null);

  const setTab = (next: Tab) => {
    const merged = new URLSearchParams();
    if (next === 'plans') merged.set('tab', 'plans');
    setParams(merged, { replace: true });
  };

  return (
    <>
      <PageHeader
        title="Memberships"
        description="Recurring plans and the customers subscribed to them."
        actions={
          canManage ? (
            tab === 'plans' ? (
              <Button
                leadingIcon={<Plus className="size-4" aria-hidden="true" />}
                onClick={() => setPlanDialog({ plan: null })}
              >
                New plan
              </Button>
            ) : (
              <Button
                leadingIcon={<Plus className="size-4" aria-hidden="true" />}
                onClick={() => setNewOpen(true)}
              >
                New membership
              </Button>
            )
          ) : undefined
        }
      />
      <Tabs
        label="Memberships sections"
        className="mb-4"
        value={tab}
        onChange={setTab}
        items={[
          {
            value: 'subscribers',
            label: 'Subscribers',
            content: <SubscribersTab onCheckout={setCheckout} onNew={() => setNewOpen(true)} />,
          },
          {
            value: 'plans',
            label: 'Plans',
            content: (
              <PlansTab
                onEdit={(plan) => setPlanDialog({ plan })}
                onNew={() => setPlanDialog({ plan: null })}
              />
            ),
          },
        ]}
      />

      <NewMembershipDialog
        open={newOpen}
        onClose={() => setNewOpen(false)}
        onCreated={(membership) => {
          setNewOpen(false);
          setCheckout(membership);
        }}
      />
      <CheckoutLinkDialog membership={checkout} onClose={() => setCheckout(null)} />
      <PlanDialog
        open={planDialog !== null}
        plan={planDialog?.plan ?? null}
        onClose={() => setPlanDialog(null)}
      />
    </>
  );
}

function SubscribersTab({
  onCheckout,
  onNew,
}: {
  onCheckout: (target: CheckoutTarget) => void;
  onNew: () => void;
}) {
  const { timezone, currency } = useShop();
  const canManage = useCan('memberships.manage');
  const [params, setParams] = useSearchParams();
  const raw = params.get('status');
  const status: MembershipStatus | 'all' = MEMBERSHIP_STATUSES.find((s) => s === raw) ?? 'all';
  const page = Math.max(1, Number(params.get('page') ?? '1') || 1);
  const subscribers = useSubscribers({ status, page });
  const [cancelling, setCancelling] = useState<SubscriberRow | null>(null);

  const setFilter = (next: { status?: string; page?: number }) => {
    const merged = new URLSearchParams(params);
    if (next.status !== undefined) {
      if (next.status === 'all') merged.delete('status');
      else merged.set('status', next.status);
    }
    if (next.page && next.page > 1) merged.set('page', String(next.page));
    else merged.delete('page');
    setParams(merged, { replace: true });
  };

  const columns: Column<SubscriberRow>[] = [
    {
      key: 'customer',
      header: 'Customer',
      primary: true,
      cell: (m) => (
        <Link
          to={`/app/customers/${m.customer_id}`}
          className="text-ink hover:text-primary-ink font-medium hover:underline"
        >
          {customerName(m.customer)}
        </Link>
      ),
    },
    {
      key: 'plan',
      header: 'Plan',
      cell: (m) =>
        m.plan ? (
          <span className="flex flex-col md:items-start">
            <span>{m.plan.name}</span>
            <span className="text-muted text-xs">
              {billingLabel(
                formatCents(m.plan.price_cents, { currency }),
                m.plan.interval,
                m.plan.interval_count,
              )}
            </span>
          </span>
        ) : (
          '—'
        ),
    },
    {
      key: 'vehicle',
      header: 'Vehicle',
      hideOnMobile: true,
      cell: (m) => (m.vehicle ? vehicleLabel(m.vehicle) : 'Any vehicle'),
    },
    {
      key: 'status',
      header: 'Status',
      cell: (m) => (
        <span className="inline-flex flex-wrap items-center justify-end gap-1.5 md:justify-start">
          <StatusBadge kind="membership" status={m.status} />
          {m.cancel_at_period_end && m.status !== 'cancelled' && (
            <Badge tone="warning">Ending</Badge>
          )}
        </span>
      ),
    },
    {
      key: 'usage',
      header: 'This period',
      hideOnMobile: true,
      cell: (m) => <UsageCell membership={m} />,
    },
    {
      key: 'period',
      header: 'Renews / ends',
      cell: (m) =>
        m.status === 'cancelled'
          ? m.cancelled_at
            ? `Ended ${formatDate(m.cancelled_at, timezone)}`
            : 'Ended'
          : m.current_period_end
            ? `${m.cancel_at_period_end ? 'Ends' : 'Renews'} ${formatDate(m.current_period_end, timezone)}`
            : '—',
    },
    ...(canManage
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (m: SubscriberRow) => {
              const items: DropdownMenuEntry[] = [];
              if (m.status === 'incomplete') {
                items.push({
                  key: 'checkout',
                  label: 'Send checkout link',
                  onSelect: () => onCheckout(m),
                });
              }
              if (
                m.status !== 'cancelled' &&
                !(m.cancel_at_period_end && m.status !== 'incomplete')
              ) {
                items.push({
                  key: 'cancel',
                  label: 'Cancel…',
                  tone: 'danger',
                  onSelect: () => setCancelling(m),
                });
              }
              if (items.length === 0) return null;
              return (
                <DropdownMenu
                  items={items}
                  trigger={(props) => (
                    <Button
                      {...props}
                      size="sm"
                      variant="ghost"
                      aria-label={`Actions for ${customerName(m.customer)}’s membership`}
                    >
                      <MoreHorizontal className="size-4" aria-hidden="true" />
                    </Button>
                  )}
                />
              );
            },
          },
        ]
      : []),
  ];

  return (
    <Card>
      <div className="flex flex-wrap items-end gap-3 p-4">
        <FormField label="Status" className="w-full sm:w-56">
          <Select
            value={status}
            onChange={(event) => setFilter({ status: event.target.value })}
            options={[
              { value: 'all', label: 'All statuses' },
              ...MEMBERSHIP_STATUSES.map((s) => ({
                value: s,
                label: statusLabel('membership', s),
              })),
            ]}
          />
        </FormField>
      </div>
      {subscribers.isPending ? (
        <LoadingState variant="rows" rows={5} label="Loading memberships…" />
      ) : subscribers.isError ? (
        <ErrorState
          error={subscribers.error}
          onRetry={() => void subscribers.refetch()}
          retrying={subscribers.isRefetching}
        />
      ) : subscribers.data.rows.length === 0 ? (
        <EmptyState
          icon={<Users aria-hidden="true" />}
          title={status === 'all' ? 'No memberships yet' : 'No memberships with this status'}
          description={
            status === 'all'
              ? 'Sign a customer up for a plan and send them the checkout link.'
              : 'Try another status.'
          }
          action={
            status === 'all' && canManage ? (
              <Button onClick={onNew}>New membership</Button>
            ) : undefined
          }
        />
      ) : (
        <>
          <Table
            caption="Memberships"
            columns={columns}
            rows={subscribers.data.rows}
            getRowId={(m) => m.id}
          />
          <Pagination
            className="border-line border-t px-4 py-3"
            page={page}
            pageSize={SUBSCRIBER_PAGE_SIZE}
            total={subscribers.data.total}
            onPageChange={(next) => setFilter({ page: next })}
          />
        </>
      )}
      <CancelMembershipDialog membership={cancelling} onClose={() => setCancelling(null)} />
    </Card>
  );
}

function PlansTab({ onEdit, onNew }: { onEdit: (plan: PlanRow) => void; onNew: () => void }) {
  const { currency } = useShop();
  const canManage = useCan('memberships.manage');
  const toast = useToast();
  const [showArchived, setShowArchived] = useState(false);
  const plans = usePlans(showArchived);
  const archive = useArchivePlan();

  const toggleArchive = async (plan: PlanRow) => {
    const archived = plan.archived_at === null;
    try {
      await archive.mutateAsync({ id: plan.id, archived });
      toast.success(archived ? `${plan.name} archived` : `${plan.name} restored`);
    } catch (error) {
      toast.error(error);
    }
  };

  const columns: Column<PlanRow>[] = [
    {
      key: 'name',
      header: 'Plan',
      primary: true,
      cell: (p) => (
        <span className="flex flex-col md:items-start">
          <span className="font-medium">{p.name}</span>
          {p.description && (
            <span className="text-muted line-clamp-1 text-xs">{p.description}</span>
          )}
        </span>
      ),
    },
    {
      key: 'price',
      header: 'Price',
      cell: (p) =>
        billingLabel(formatCents(p.price_cents, { currency }), p.interval, p.interval_count),
    },
    {
      key: 'included',
      header: 'Included',
      hideOnMobile: true,
      cell: (p) =>
        p.included_service_ids.length === 0
          ? 'None'
          : `${p.included_service_ids.length} service${p.included_service_ids.length === 1 ? '' : 's'}`,
    },
    {
      key: 'discount',
      header: 'Discount',
      cell: (p) => (p.discount_bps > 0 ? `${formatBps(p.discount_bps)} off` : '—'),
    },
    {
      key: 'uses',
      header: 'Visits / period',
      hideOnMobile: true,
      cell: (p) =>
        p.included_service_ids.length === 0
          ? '—'
          : p.included_uses_per_period === null
            ? 'Unlimited'
            : String(p.included_uses_per_period),
    },
    {
      key: 'status',
      header: 'Status',
      cell: (p) => (
        <span className="inline-flex flex-wrap items-center justify-end gap-1.5 md:justify-start">
          {p.archived_at ? (
            <Badge tone="neutral">Archived</Badge>
          ) : p.active ? (
            <Badge tone="success">Active</Badge>
          ) : (
            <Badge tone="neutral">Hidden</Badge>
          )}
          {p.online_joinable && p.active && !p.archived_at && <Badge tone="info">Online</Badge>}
        </span>
      ),
    },
    ...(canManage
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (p: PlanRow) => (
              <DropdownMenu
                items={[
                  { key: 'edit', label: 'Edit', onSelect: () => onEdit(p) },
                  {
                    key: 'archive',
                    label: p.archived_at ? 'Restore' : 'Archive',
                    onSelect: () => void toggleArchive(p),
                  },
                ]}
                trigger={(props) => (
                  <Button {...props} size="sm" variant="ghost" aria-label={`Actions for ${p.name}`}>
                    <MoreHorizontal className="size-4" aria-hidden="true" />
                  </Button>
                )}
              />
            ),
          },
        ]
      : []),
  ];

  const sellsOnline = (plans.data ?? []).some(
    (p) => p.online_joinable && p.active && p.archived_at === null,
  );

  return (
    <div className="flex flex-col gap-4">
      {sellsOnline && <JoinPageCard />}
      <Card>
        <div className="flex flex-wrap items-center justify-between gap-3 p-4">
          <Switch
            checked={showArchived}
            onCheckedChange={setShowArchived}
            label="Show archived plans"
          />
        </div>
        {plans.isPending ? (
          <LoadingState variant="rows" rows={4} label="Loading plans…" />
        ) : plans.isError ? (
          <ErrorState
            error={plans.error}
            onRetry={() => void plans.refetch()}
            retrying={plans.isRefetching}
          />
        ) : plans.data.length === 0 ? (
          <EmptyState
            icon={<BadgePercent aria-hidden="true" />}
            title="No membership plans yet"
            description="Create a plan with a recurring price, included services and a member discount."
            action={canManage ? <Button onClick={onNew}>New plan</Button> : undefined}
          />
        ) : (
          <Table
            caption="Membership plans"
            columns={columns}
            rows={plans.data}
            getRowId={(p) => p.id}
          />
        )}
      </Card>
    </div>
  );
}

/** Uses of the included services this billing period (plans with included services). */
function UsageCell({ membership }: { membership: SubscriberRow }) {
  const tracked =
    membership.plan !== null &&
    (membership.status === 'active' || membership.status === 'past_due');
  const usage = useMembershipUsage(membership.id, tracked);
  if (!tracked) return <span className="text-muted">—</span>;
  if (usage.isPending) return <span className="text-muted">…</span>;
  if (usage.isError) return <span className="text-muted">Unavailable</span>;
  const full =
    usage.data.uses_per_period !== null &&
    usage.data.uses_this_period >= usage.data.uses_per_period;
  return <span className={full ? 'text-warning-ink' : undefined}>{usageText(usage.data)}</span>;
}

/** The shop's public join page: link + QR for the counter or the website. */
function JoinPageCard() {
  const { shop } = useShop();
  const url = `${window.location.origin}/join/${encodeURIComponent(shop.slug)}`;
  return (
    <SectionCard
      title="Online join page"
      description="Plans marked “Sell online” are listed here. Customers join and pay by card."
    >
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start">
        <CopyField label="Join page link" value={url} className="min-w-0 flex-1" />
        <QrCode
          value={url}
          label="QR code for your membership join page"
          fileName={`${shop.slug}-memberships`}
          size={120}
        />
      </div>
    </SectionCard>
  );
}
