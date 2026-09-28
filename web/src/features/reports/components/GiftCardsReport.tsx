import { Gift } from 'lucide-react';
import { EmptyState, SectionCard } from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useGiftCardsReport } from '../api';
import { centsCell, toCsv } from '../csv';
import { countOf, type GiftCardsReport as GiftCardsData } from '../model';
import { rangeFileSuffix, type DateRange } from '../ranges';
import { CsvButton, ReportState, StatGrid, StatTile } from './shared';

/**
 * Gift cards and store credit (report_gift_cards, 0066). Gift cards are
 * tender, not revenue: sales are money received for future work, and the
 * revenue is recorded when a card pays an invoice.
 */
export function GiftCardsReport({ range }: { range: DateRange }) {
  const query = useGiftCardsReport(range);
  return (
    <ReportState query={query} title="Gift cards">
      {() => (query.data ? <GiftCardsBody data={query.data} range={range} /> : null)}
    </ReportState>
  );
}

function GiftCardsBody({ data, range }: { data: GiftCardsData; range: DateRange }) {
  const { currency } = useShop();
  const money = (cents: number) => formatCents(cents, { currency });
  const empty =
    data.sold_count === 0 &&
    data.redeemed_cents === 0 &&
    data.outstanding_liability_cents === 0 &&
    data.expired_cents === 0 &&
    data.credit_issued_cents === 0;

  if (empty)
    return (
      <SectionCard title="Gift cards">
        <EmptyState
          icon={<Gift aria-hidden="true" />}
          title="No gift card activity"
          description="Gift cards sold, redeemed and still outstanding show up here."
        />
      </SectionCard>
    );

  const csv = () =>
    toCsv(
      ['Measure', 'Value'],
      [
        ['Gift cards sold', data.sold_count],
        ['Value of cards sold', centsCell(data.sold_value_cents)],
        ['Paid for cards sold', centsCell(data.sold_price_cents)],
        ['Redeemed', centsCell(data.redeemed_cents)],
        ['Expired unused', centsCell(data.expired_cents)],
        ['Store credit issued', centsCell(data.credit_issued_cents)],
        ['Outstanding balance at end of period', centsCell(data.outstanding_liability_cents)],
      ],
    );

  return (
    <SectionCard
      title="Gift cards & store credit"
      description="Sales are money received for future work; revenue is counted when a card pays an invoice."
      actions={<CsvButton filename={`gift_cards_${rangeFileSuffix(range)}.csv`} build={csv} />}
    >
      <div className="flex flex-col gap-4">
        <StatGrid label="Gift card totals">
          <StatTile
            label="Sold"
            value={money(data.sold_value_cents)}
            hint={`${countOf(data.sold_count, 'card')} · ${money(data.sold_price_cents)} paid`}
          />
          <StatTile
            label="Redeemed"
            value={money(data.redeemed_cents)}
            hint="Used to pay invoices"
          />
          <StatTile
            label="Outstanding"
            value={money(data.outstanding_liability_cents)}
            hint="Unused balance at the end of the period"
          />
          <StatTile label="Expired unused" value={money(data.expired_cents)} />
        </StatGrid>
        <p className="text-muted text-sm">
          Store credit issued (referral rewards and credits): {money(data.credit_issued_cents)}.
        </p>
      </div>
    </SectionCard>
  );
}
