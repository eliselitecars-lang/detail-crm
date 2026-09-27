import type { ReactNode } from 'react';
import { Badge, KeyValueList, SectionCard, type KeyValueItem } from '@/components/ui';
import { formatBps, formatCents } from '@/lib/money';

export interface TotalsCardProps {
  currency: string;
  subtotalCents: number;
  discountCents: number;
  taxCents: number;
  taxRateBps: number;
  totalCents: number;
  /** Invoices only. */
  paidCents?: number;
  tipCents?: number;
  balanceCents?: number;
  footer?: ReactNode;
  title?: string;
}

/**
 * Document totals exactly as the server stored them (SPEC §4.5) — nothing
 * is added up here. Money tone (amber) only on the amount owed.
 */
export function TotalsCard({
  currency,
  subtotalCents,
  discountCents,
  taxCents,
  taxRateBps,
  totalCents,
  paidCents,
  tipCents,
  balanceCents,
  footer,
  title = 'Totals',
}: TotalsCardProps) {
  const money = (cents: number) => formatCents(cents, { currency });
  const items: KeyValueItem[] = [
    {
      key: 'subtotal',
      label: 'Subtotal',
      value: <span className="tabular-nums">{money(subtotalCents)}</span>,
    },
  ];
  if (discountCents > 0) {
    items.push({
      key: 'discount',
      label: 'Discount',
      value: <span className="tabular-nums">−{money(discountCents)}</span>,
    });
  }
  items.push(
    {
      key: 'tax',
      label: `Tax (${formatBps(taxRateBps)})`,
      value: <span className="tabular-nums">{money(taxCents)}</span>,
    },
    {
      key: 'total',
      label: 'Total',
      emphasis: true,
      value: <span className="tabular-nums">{money(totalCents)}</span>,
    },
  );
  if (paidCents !== undefined) {
    items.push({
      key: 'paid',
      label: 'Paid',
      value: <span className="tabular-nums">{money(paidCents)}</span>,
    });
  }
  if (tipCents !== undefined && tipCents > 0) {
    items.push({
      key: 'tips',
      label: 'Tips (not in balance)',
      value: <span className="tabular-nums">{money(tipCents)}</span>,
    });
  }
  if (balanceCents !== undefined) {
    items.push({
      key: 'balance',
      label: 'Balance due',
      emphasis: true,
      value:
        balanceCents > 0 ? (
          <Badge tone="money">{money(balanceCents)}</Badge>
        ) : balanceCents < 0 ? (
          <Badge tone="info">Credit {money(-balanceCents)}</Badge>
        ) : (
          <Badge tone="success">Paid in full</Badge>
        ),
    });
  }
  return (
    <SectionCard title={title} footer={footer}>
      <KeyValueList items={items} />
    </SectionCard>
  );
}
