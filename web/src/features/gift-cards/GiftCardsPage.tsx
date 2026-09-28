import { ExternalLink, Gift, Plus } from 'lucide-react';
import { useState } from 'react';
import { useSearchParams } from 'react-router';
import {
  Badge,
  Button,
  buttonClasses,
  Card,
  EmptyState,
  ErrorState,
  FormField,
  LoadingState,
  PageHeader,
  Pagination,
  SearchInput,
  Select,
  Table,
  type Column,
} from '@/components/ui';
import { formatDate } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import { customerName } from '@/features/quotes/shared/format';
import { useShopLapsed } from '@/features/billing/api';
import { LapsedNotice } from '@/features/billing/components/LapsedNotice';
import {
  effectiveCardStatus,
  GIFT_CARD_PAGE_SIZE,
  GIFT_CARD_STATUSES,
  KIND_LABELS,
  STATUS_LABELS,
  useGiftCards,
  useGiftCardSettings,
  type GiftCardKind,
  type GiftCardRow,
  type GiftCardStatus,
} from './api';
import { IssueGiftCardDialog } from './components/IssueGiftCardDialog';
import { CardStatusBadge } from './components/CardStatusBadge';

const KINDS = ['gift', 'credit'] as const satisfies readonly GiftCardKind[];

/** /app/gift-cards — every gift card and store credit of the shop (managers+). */
export default function GiftCardsPage() {
  const { shopId, timezone, currency, shop } = useShop();
  const canIssue = useCan('giftCards.manage');
  // A lapsed shop sells no gift cards, online or by staff (0103).
  const lapsed = useShopLapsed(shopId);
  const settings = useGiftCardSettings();
  const [params, setParams] = useSearchParams();
  const rawKind = params.get('kind');
  const rawStatus = params.get('status');
  const kind: GiftCardKind | 'all' = KINDS.find((k) => k === rawKind) ?? 'all';
  const status: GiftCardStatus | 'all' = GIFT_CARD_STATUSES.find((s) => s === rawStatus) ?? 'all';
  const search = params.get('q') ?? '';
  const page = Math.max(1, Number(params.get('page') ?? '1') || 1);
  const cards = useGiftCards({ kind, status, search, page });
  const [issueOpen, setIssueOpen] = useState(false);

  const setFilter = (next: { kind?: string; status?: string; q?: string; page?: number }) => {
    const merged = new URLSearchParams(params);
    for (const [key, value] of Object.entries(next)) {
      if (key === 'page') continue;
      if (value === undefined) continue;
      if (value === '' || value === 'all') merged.delete(key);
      else merged.set(key, String(value));
    }
    if (next.page && next.page > 1) merged.set('page', String(next.page));
    else merged.delete('page');
    setParams(merged, { replace: true });
  };

  const columns: Column<GiftCardRow>[] = [
    {
      key: 'code',
      header: 'Card',
      primary: true,
      cell: (c) => (
        <span className="flex flex-col md:items-start">
          <span className="font-mono font-medium">…{c.code_last4}</span>
          <span className="text-muted text-xs">{KIND_LABELS[c.kind]}</span>
        </span>
      ),
    },
    {
      key: 'holder',
      header: 'For',
      cell: (c) =>
        c.owner
          ? customerName(c.owner)
          : c.recipient_name ||
            c.recipient_email ||
            (c.purchaser ? customerName(c.purchaser) : '—'),
    },
    {
      key: 'status',
      header: 'Status',
      cell: (c) => <CardStatusBadge status={effectiveCardStatus(c)} />,
    },
    {
      key: 'issued',
      header: 'Issued',
      hideOnMobile: true,
      cell: (c) => formatDate(c.created_at, timezone),
    },
    {
      key: 'value',
      header: 'Value',
      align: 'right',
      hideOnMobile: true,
      cell: (c) => <span className="tabular">{formatCents(c.initial_cents, { currency })}</span>,
    },
    {
      key: 'balance',
      header: 'Balance',
      align: 'right',
      cell: (c) => (
        <span className={c.balance_cents > 0 ? 'tabular text-money-ink font-medium' : 'tabular'}>
          {formatCents(c.balance_cents, { currency })}
        </span>
      ),
    },
  ];

  const onlineSetting = settings.data?.online_enabled === true;
  const onlineOn = onlineSetting && !lapsed;
  const filtered = kind !== 'all' || status !== 'all' || search.trim() !== '';

  return (
    <>
      <PageHeader
        title="Gift cards"
        description="Gift cards and store credit. Cards are paid off invoices like cash; the code is only ever shown once."
        meta={
          onlineOn ? (
            <Badge tone="success">Selling online</Badge>
          ) : onlineSetting && lapsed ? (
            <Badge tone="warning">Online sales paused</Badge>
          ) : undefined
        }
        actions={
          <div className="flex flex-wrap gap-2">
            {onlineOn && (
              <a
                href={`/gift/${encodeURIComponent(shop.slug)}`}
                target="_blank"
                rel="noopener noreferrer"
                className={buttonClasses({ variant: 'secondary' })}
              >
                <ExternalLink className="size-4" aria-hidden="true" />
                Online shop
              </a>
            )}
            {canIssue && (
              <Button
                leadingIcon={<Plus className="size-4" aria-hidden="true" />}
                onClick={() => setIssueOpen(true)}
                disabled={lapsed}
              >
                Issue gift card
              </Button>
            )}
          </div>
        }
      />
      {lapsed && (
        <LapsedNotice>
          Selling gift cards is paused while this shop’s subscription is inactive: the online gift
          card shop tells customers sales are off, and new gift cards can’t be issued. Existing
          cards can still be redeemed.
        </LapsedNotice>
      )}
      <Card>
        <div className="flex flex-wrap items-end gap-3 p-4">
          <div className="w-full sm:w-72">
            <SearchInput
              label="Search gift cards"
              placeholder="Last 4 of the code, name or email…"
              value={search}
              onChange={(q) => setFilter({ q })}
            />
          </div>
          <FormField label="Type" className="w-full sm:w-44">
            <Select
              value={kind}
              onChange={(event) => setFilter({ kind: event.target.value })}
              options={[
                { value: 'all', label: 'All types' },
                ...KINDS.map((k) => ({ value: k, label: KIND_LABELS[k] })),
              ]}
            />
          </FormField>
          <FormField label="Status" className="w-full sm:w-44">
            <Select
              value={status}
              onChange={(event) => setFilter({ status: event.target.value })}
              options={[
                { value: 'all', label: 'All statuses' },
                ...GIFT_CARD_STATUSES.map((s) => ({ value: s, label: STATUS_LABELS[s] })),
              ]}
            />
          </FormField>
        </div>
        {cards.isPending ? (
          <LoadingState variant="rows" rows={5} label="Loading gift cards…" />
        ) : cards.isError ? (
          <ErrorState
            error={cards.error}
            onRetry={() => void cards.refetch()}
            retrying={cards.isRefetching}
          />
        ) : cards.data.rows.length === 0 ? (
          <EmptyState
            icon={<Gift aria-hidden="true" />}
            title={filtered ? 'No cards match' : 'No gift cards yet'}
            description={
              filtered
                ? 'Try another search or filter.'
                : 'Issue a card at the counter, or sell them online from Settings → Gift cards.'
            }
            action={
              !filtered && canIssue ? (
                <Button onClick={() => setIssueOpen(true)} disabled={lapsed}>
                  Issue gift card
                </Button>
              ) : undefined
            }
          />
        ) : (
          <>
            <Table
              caption="Gift cards"
              columns={columns}
              rows={cards.data.rows}
              getRowId={(c) => c.id}
              rowHref={(c) => `/app/gift-cards/${c.id}`}
            />
            <Pagination
              className="border-line border-t px-4 py-3"
              page={page}
              pageSize={GIFT_CARD_PAGE_SIZE}
              total={cards.data.total}
              onPageChange={(next) => setFilter({ page: next })}
            />
          </>
        )}
      </Card>
      {canIssue && <IssueGiftCardDialog open={issueOpen} onClose={() => setIssueOpen(false)} />}
    </>
  );
}
