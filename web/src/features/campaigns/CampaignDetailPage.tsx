import { Ban, SearchX } from 'lucide-react';
import { useState } from 'react';
import { useParams } from 'react-router';
import {
  Button,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  KeyValueList,
  LoadingState,
  PageHeader,
  SectionCard,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { useRealtime } from '@/lib/useRealtime';
import { useShop } from '@/features/shop/shopContext';
import {
  campaignKeys,
  useCampaign,
  useCampaignStats,
  useCancelCampaign,
  type Campaign,
} from './api';
import { CampaignEditor } from './components/CampaignEditor';
import { CampaignStatusBadge } from './components/CampaignStatusBadge';
import { audienceSchema, describeAudience } from './model';

export default function CampaignDetailPage() {
  const { campaignId } = useParams();
  const campaign = useCampaign(campaignId);

  if (campaign.isPending)
    return (
      <>
        <PageHeader title="Campaign" back={{ to: '/app/campaigns', label: 'Campaigns' }} />
        <LoadingState label="Loading campaign…" />
      </>
    );
  if (campaign.error)
    return (
      <>
        <PageHeader title="Campaign" back={{ to: '/app/campaigns', label: 'Campaigns' }} />
        {toAppError(campaign.error).kind === 'not_found' ? (
          <EmptyState
            icon={<SearchX aria-hidden="true" />}
            title="Campaign not found"
            description="It may have been deleted."
          />
        ) : (
          <ErrorState
            error={campaign.error}
            title="Couldn’t load this campaign"
            onRetry={() => void campaign.refetch()}
            retrying={campaign.isRefetching}
          />
        )}
      </>
    );

  const c = campaign.data;
  if (c.status === 'draft')
    return (
      <>
        <PageHeader
          title={c.name}
          meta={<CampaignStatusBadge status={c.status} />}
          back={{ to: '/app/campaigns', label: 'Campaigns' }}
        />
        <CampaignEditor key={c.id} campaign={c} />
      </>
    );
  return <CampaignSummary campaign={c} />;
}

function CampaignSummary({ campaign: c }: { campaign: Campaign }) {
  const { shopId, timezone } = useShop();
  const toast = useToast();
  const stats = useCampaignStats(c.id, c.status, c.recipient_count);
  const cancel = useCancelCampaign();
  const [confirmCancel, setConfirmCancel] = useState(false);
  useRealtime({ table: 'messages', shopId, invalidate: [campaignKeys.stats(shopId, c.id)] });

  const audience = audienceSchema.safeParse(c.audience);
  const pending = stats.data?.pending ?? 0;

  return (
    <>
      <PageHeader
        title={c.name}
        meta={<CampaignStatusBadge status={c.status} />}
        back={{ to: '/app/campaigns', label: 'Campaigns' }}
        actions={
          c.status === 'launched' ? (
            <Button
              variant="danger"
              leadingIcon={<Ban />}
              disabled={stats.isPending || pending === 0}
              title={pending === 0 ? 'Every message has already been sent.' : undefined}
              onClick={() => setConfirmCancel(true)}
            >
              Cancel unsent messages
            </Button>
          ) : undefined
        }
      />
      <div className="flex flex-col gap-5">
        <SectionCard title="Delivery">
          {stats.isPending ? (
            <LoadingState label="Loading delivery status…" />
          ) : stats.error ? (
            <ErrorState
              error={stats.error}
              onRetry={() => void stats.refetch()}
              retrying={stats.isRefetching}
              compact
            />
          ) : (
            <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
              {(
                [
                  ['Recipients', stats.data.recipients, 'text-ink'],
                  ['Queued', stats.data.pending, 'text-ink'],
                  ['Sent', stats.data.sent, 'text-primary-ink'],
                  ['Delivered', stats.data.delivered, 'text-success-ink'],
                  ['Failed', stats.data.failed, 'text-danger-ink'],
                  ['Cancelled', stats.data.cancelled, 'text-muted'],
                ] as const
              ).map(([label, value, tone]) => (
                <div key={label} className="bg-surface-2 rounded-control p-3">
                  <dt className="text-muted text-xs font-medium">{label}</dt>
                  <dd className={`mt-1 text-2xl font-semibold tabular-nums ${tone}`}>
                    {value.toLocaleString()}
                  </dd>
                </div>
              ))}
            </dl>
          )}
          <p className="text-muted mt-3 text-xs">
            “Sent” means the provider accepted the message; carriers confirm “Delivered” for texts
            when they report it.
          </p>
        </SectionCard>

        <SectionCard title="Details">
          <KeyValueList
            items={[
              { label: 'Channel', value: c.channel === 'sms' ? 'Text message' : 'Email' },
              {
                label: 'Audience',
                value: audience.success
                  ? describeAudience(audience.data, c.channel)
                  : 'Custom audience',
              },
              { label: 'Launched', value: formatDateTime(c.launched_at, timezone) },
              {
                label: 'Send time',
                value: c.scheduled_at ? formatDateTime(c.scheduled_at, timezone) : 'At launch',
              },
              ...(c.cancelled_at
                ? [{ label: 'Cancelled', value: formatDateTime(c.cancelled_at, timezone) }]
                : []),
            ]}
          />
        </SectionCard>

        <SectionCard title="Message">
          {c.subject && <p className="text-ink mb-2 font-semibold">{c.subject}</p>}
          <p className="text-ink text-sm whitespace-pre-wrap">{c.body}</p>
        </SectionCard>
      </div>

      <ConfirmDialog
        open={confirmCancel}
        onClose={() => setConfirmCancel(false)}
        tone="danger"
        loading={cancel.isPending}
        title="Cancel unsent messages?"
        description={`${pending.toLocaleString()} queued ${pending === 1 ? 'message is' : 'messages are'} withdrawn. Messages already sent stay sent. This can’t be undone.`}
        confirmLabel="Cancel campaign"
        cancelLabel="Keep sending"
        onConfirm={async () => {
          try {
            await cancel.mutateAsync(c.id);
            toast.success('Campaign cancelled');
          } catch (error) {
            toast.error(error);
          } finally {
            setConfirmCancel(false);
          }
        }}
      />
    </>
  );
}
