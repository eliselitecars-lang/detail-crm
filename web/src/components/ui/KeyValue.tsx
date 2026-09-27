import type { ReactNode } from 'react';
import { cn } from '@/lib/cn';

export interface KeyValueItem {
  label: ReactNode;
  value: ReactNode;
  /** Visually emphasise (e.g. balance due). */
  emphasis?: boolean;
  key?: string;
}

export interface KeyValueListProps {
  items: readonly KeyValueItem[];
  /** "rows": label left / value right. "grid": label above value in columns. */
  layout?: 'rows' | 'grid';
  className?: string;
}

/** Definition list for record details. Empty values render as "—". */
export function KeyValueList({ items, layout = 'rows', className }: KeyValueListProps) {
  const show = (value: ReactNode) =>
    value === null || value === undefined || value === '' ? (
      <span className="text-subtle">—</span>
    ) : (
      value
    );
  if (layout === 'grid') {
    return (
      <dl
        className={cn('grid grid-cols-1 gap-x-6 gap-y-4 sm:grid-cols-2 lg:grid-cols-3', className)}
      >
        {items.map((item, i) => (
          <div key={item.key ?? i} className="min-w-0">
            <dt className="text-muted text-xs font-medium">{item.label}</dt>
            <dd
              className={cn(
                'text-ink mt-0.5 text-sm break-words',
                item.emphasis && 'font-semibold',
              )}
            >
              {show(item.value)}
            </dd>
          </div>
        ))}
      </dl>
    );
  }
  return (
    <dl className={cn('divide-line divide-y', className)}>
      {items.map((item, i) => (
        // Long emails, VINs and addresses wrap inside the row instead of
        // widening the page on phones: the value shrinks (min-w-0) and breaks,
        // the label keeps its words intact up to 45% of the row.
        <div key={item.key ?? i} className="flex items-baseline justify-between gap-4 py-2">
          <dt className="text-muted max-w-[45%] shrink-0 text-sm break-words">{item.label}</dt>
          <dd
            className={cn(
              'text-ink min-w-0 text-right text-sm break-words',
              item.emphasis && 'font-semibold',
            )}
          >
            {show(item.value)}
          </dd>
        </div>
      ))}
    </dl>
  );
}
