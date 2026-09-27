import type { ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { formatCents } from '@/lib/money';
import type { PublicLine } from './schemas';
import type { TotalRow } from './totals';

function quantityText(quantity: number): string {
  return Number.isInteger(quantity) ? String(quantity) : quantity.toFixed(2).replace(/0$/, '');
}

/** One priced line: name, details, "2 × $50.00", line total (all server values). */
export function LineRow({
  line,
  currency,
  leading,
  trailingNote,
}: {
  line: PublicLine;
  currency: string;
  leading?: ReactNode;
  trailingNote?: ReactNode;
}) {
  return (
    <li className="flex items-start gap-3 py-3">
      {leading}
      <div className="min-w-0 flex-1">
        <p className="text-ink text-sm font-medium break-words">{line.name}</p>
        {line.description && (
          <p className="text-muted mt-0.5 text-xs break-words whitespace-pre-line">
            {line.description}
          </p>
        )}
        <p className="text-muted mt-0.5 text-xs">
          {[
            line.vehicle_label,
            line.quantity !== 1
              ? `${quantityText(line.quantity)} × ${formatCents(line.unit_price_cents, { currency })}`
              : null,
            line.discount_cents > 0
              ? `${formatCents(line.discount_cents, { currency })} off`
              : null,
          ]
            .filter(Boolean)
            .join(' · ')}
        </p>
        {trailingNote}
      </div>
      <p className="text-ink shrink-0 text-sm font-medium tabular-nums">
        {formatCents(line.total_cents, { currency })}
      </p>
    </li>
  );
}

export function LineList({
  lines,
  currency,
  label,
}: {
  lines: readonly PublicLine[];
  currency: string;
  label: string;
}) {
  if (lines.length === 0) {
    return <p className="text-muted py-3 text-sm">No items.</p>;
  }
  return (
    <ul aria-label={label} className="divide-line divide-y">
      {lines.map((line, i) => (
        <LineRow key={i} line={line} currency={currency} />
      ))}
    </ul>
  );
}

/** Server totals. The client never adds these up. */
export function TotalsList({ rows, currency }: { rows: readonly TotalRow[]; currency: string }) {
  return (
    <dl className="flex flex-col gap-1.5 text-sm">
      {rows.map((row) => (
        <div
          key={row.key}
          className={cn(
            'flex items-baseline justify-between gap-4',
            row.emphasis && 'border-line border-t pt-2 text-base font-semibold',
          )}
        >
          <dt className={row.emphasis ? 'text-ink' : 'text-muted'}>{row.label}</dt>
          <dd
            className={cn(
              'tabular-nums',
              row.money ? 'text-money-ink' : 'text-ink',
              row.emphasis && 'font-semibold',
            )}
          >
            {row.negative && row.cents > 0 ? '−' : ''}
            {formatCents(row.cents, { currency })}
          </dd>
        </div>
      ))}
    </dl>
  );
}
