import { Mail, Megaphone, MessageSquare, Plus } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router';
import {
  buttonClasses,
  Card,
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  Table,
  Tabs,
  type Column,
} from '@/components/ui';
import { formatDate, formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCampaigns, type CampaignListRow } from './api';
import { CampaignStatusBadge } from './components/CampaignStatusBadge';
import type { CampaignStatus } from './model';

type Filter = 'all' | CampaignStatus;

export default function CampaignsPage() {
  const { timezone } = useShop();
  const campaigns = useCampaigns();
  const [filter, setFilter] = useState<Filter>('all');
  const rows = campaigns.data ?? [];
  const visible = filter === 'all' ? rows : rows.filter((c) => c.status === filter);
  const count = (status: CampaignStatus) => rows.filter((c) => c.status === status).length;

  const columns: Column<CampaignListRow>[] = [
    { key: 'name', header: 'Name', primary: true, cell: (c) => c.name },
    {
      key: 'channel',
      header: 'Channel',
      cell: (c) => (
        <span className="inline-flex items-center gap-1.5">
          {c.channel === 'sms' ? (
            <MessageSquare className="text-muted size-4" aria-hidden="true" />
          ) : (
            <Mail className="text-muted size-4" aria-hidden="true" />
          )}
          {c.channel === 'sms' ? 'Text' : 'Email'}
        </span>
      ),
    },
    { key: 'status', header: 'Status', cell: (c) => <CampaignStatusBadge status={c.status} /> },
    {
      key: 'recipients',
      header: 'Recipients',
      align: 'right',
      cell: (c) => (c.status === 'draft' ? '—' : c.recipient_count.toLocaleString()),
    },
    {
      key: 'when',
      header: 'Date',
      cell: (c) =>
        c.status === 'launched' && c.launched_at
          ? `Launched ${formatDate(c.launched_at, timezone)}`
          : c.status === 'cancelled' && c.cancelled_at
            ? `Cancelled ${formatDate(c.cancelled_at, timezone)}`
            : c.scheduled_at
              ? `Send at ${formatDateTime(c.scheduled_at, timezone)}`
              : `Edited ${formatDate(c.updated_at, timezone)}`,
    },
  ];

  const newButton = (
    <Link to="/app/campaigns/new" className={buttonClasses({ variant: 'primary' })}>
      <Plus className="size-4" aria-hidden="true" />
      New campaign
    </Link>
  );

  let content;
  if (campaigns.isPending) content = <LoadingState label="Loading campaigns…" variant="rows" />;
  else if (campaigns.error)
    content = (
      <ErrorState
        error={campaigns.error}
        title="Couldn’t load campaigns"
        onRetry={() => void campaigns.refetch()}
        retrying={campaigns.isRefetching}
      />
    );
  else if (rows.length === 0)
    content = (
      <EmptyState
        icon={<Megaphone aria-hidden="true" />}
        title="No campaigns yet"
        description="Send a text or email to opted-in customers — filter by tags, lifecycle or last visit."
        action={newButton}
      />
    );
  else
    content = (
      <>
        <Tabs<Filter>
          label="Filter by status"
          value={filter}
          onChange={setFilter}
          items={[
            { value: 'all', label: 'All', count: rows.length },
            { value: 'draft', label: 'Drafts', count: count('draft') },
            { value: 'launched', label: 'Launched', count: count('launched') },
            { value: 'cancelled', label: 'Cancelled', count: count('cancelled') },
          ]}
          className="px-4 pt-2"
        />
        {visible.length === 0 ? (
          <EmptyState title="No campaigns with this status" compact />
        ) : (
          <Table
            caption="Campaigns"
            columns={columns}
            rows={visible}
            getRowId={(c) => c.id}
            rowHref={(c) => `/app/campaigns/${c.id}`}
          />
        )}
      </>
    );

  return (
    <>
      <PageHeader
        title="Campaigns"
        description="Text and email blasts to opted-in customers."
        actions={rows.length > 0 ? newButton : undefined}
      />
      <Card>{content}</Card>
    </>
  );
}
