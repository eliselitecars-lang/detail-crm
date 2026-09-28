import { History } from 'lucide-react';
import { Link } from 'react-router';
import { Drawer, EmptyState, ErrorState, LoadingState } from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatDateTime } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { MOVEMENTS_LIMIT, useMovements } from '../api';
import { formatQty, MOVEMENT_LABELS, type Product } from '../model';

/** A product's stock history (latest first). */
export function MovementsDrawer({ product, onClose }: { product: Product; onClose: () => void }) {
  const { timezone, currency } = useShop();
  const movements = useMovements(product.id);
  const rows = movements.data ?? [];
  return (
    <Drawer
      open
      onClose={onClose}
      title={`${product.name} · stock history`}
      description={`On hand: ${formatQty(product.on_hand)} ${product.unit}`}
      widthClassName="max-w-lg"
    >
      {movements.isPending ? (
        <LoadingState variant="rows" rows={5} label="Loading stock history…" />
      ) : movements.isError ? (
        <ErrorState
          error={movements.error}
          title="Couldn’t load the history"
          onRetry={() => void movements.refetch()}
          retrying={movements.isRefetching}
        />
      ) : rows.length === 0 ? (
        <EmptyState
          icon={<History aria-hidden="true" />}
          title="No stock changes yet"
          description="Receipts, adjustments, counts and job usage appear here."
        />
      ) : (
        <>
          <ol className="divide-line divide-y" aria-label="Stock changes">
            {rows.map((m) => (
              <li key={m.id} className="flex items-start gap-3 py-3">
                <div className="min-w-0 flex-1">
                  <p className="text-ink text-sm font-medium">
                    {MOVEMENT_LABELS[m.kind]}
                    {m.job && (
                      <>
                        {' '}
                        <Link
                          to={`/app/jobs/${m.job.id}`}
                          className="text-primary-ink hover:underline"
                        >
                          job #{m.job.number}
                        </Link>
                      </>
                    )}
                  </p>
                  <p className="text-muted text-xs">
                    <time dateTime={m.created_at}>{formatDateTime(m.created_at, timezone)}</time>
                    {m.unit_cost_cents !== null &&
                      ` · ${formatCents(m.unit_cost_cents, { currency })} per ${product.unit}`}
                  </p>
                  {m.note && <p className="text-muted text-xs break-words">{m.note}</p>}
                </div>
                <span
                  className={cn(
                    'tabular shrink-0 text-sm font-medium',
                    m.quantity < 0 ? 'text-danger-ink' : 'text-ink',
                  )}
                >
                  {m.quantity > 0 ? '+' : ''}
                  {formatQty(m.quantity)}
                </span>
              </li>
            ))}
          </ol>
          {rows.length >= MOVEMENTS_LIMIT && (
            <p className="text-muted pt-2 text-xs">The latest {MOVEMENTS_LIMIT} changes.</p>
          )}
        </>
      )}
    </Drawer>
  );
}
