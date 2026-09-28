import { ArrowDown, ArrowUp, ArrowUpDown } from 'lucide-react';
import type { ReactNode } from 'react';
import { Link, useNavigate } from 'react-router';
import { cn } from '@/lib/cn';
import { Button } from './Button';
import { Select } from './Select';

export type SortDirection = 'asc' | 'desc';

export interface SortState<K extends string = string> {
  key: K;
  direction: SortDirection;
}

export interface Column<T, K extends string = string> {
  key: K;
  header: ReactNode;
  cell: (row: T) => ReactNode;
  sortable?: boolean;
  /** Plain-text name for the stacked-layout "Sort by" picker (defaults to a string `header`). */
  sortLabel?: string;
  align?: 'left' | 'right' | 'center';
  /** Title cell in the stacked (mobile) layout; also hosts the row link. */
  primary?: boolean;
  /** Hide in the stacked (mobile) layout. */
  hideOnMobile?: boolean;
  className?: string;
  headerClassName?: string;
}

export interface TableProps<T, K extends string = string> {
  /** Accessible caption (visually hidden). */
  caption: string;
  columns: readonly Column<T, K>[];
  rows: readonly T[];
  getRowId: (row: T) => string;
  sort?: SortState<K> | null;
  onSortChange?: (sort: SortState<K>) => void;
  /**
   * Sort keys with no column of their own (e.g. "Last updated"), offered in
   * the stacked layout's "Sort by" picker next to the sortable columns.
   */
  extraSortOptions?: readonly { key: K; label: string }[];
  /** Makes rows navigable: the primary cell becomes a link, the row is clickable. */
  rowHref?: (row: T) => string;
  className?: string;
}

const alignClass = { left: 'text-left', right: 'text-right', center: 'text-center' } as const;

function ariaSort(sort: SortState | null | undefined, key: string) {
  if (!sort || sort.key !== key) return 'none' as const;
  return sort.direction === 'asc' ? ('ascending' as const) : ('descending' as const);
}

/**
 * Data table with sortable headers (server- or client-side — the caller
 * sorts `rows`) and a stacked card layout below the `md` breakpoint. The
 * stacked layout has no headers to click, so it gets a "Sort by" picker and
 * a direction toggle instead (same `onSortChange`).
 * Loading/empty/error states are rendered by the caller around it.
 */
export function Table<T, K extends string = string>({
  caption,
  columns,
  rows,
  getRowId,
  sort,
  onSortChange,
  extraSortOptions,
  rowHref,
  className,
}: TableProps<T, K>) {
  const navigate = useNavigate();
  const primary = columns.find((c) => c.primary) ?? columns[0];
  const sortOptions = onSortChange
    ? [
        ...columns
          .filter((c) => c.sortable)
          .map((c) => ({
            value: c.key,
            label: c.sortLabel ?? (typeof c.header === 'string' ? c.header : c.key),
          })),
        ...(extraSortOptions ?? []).map((o) => ({ value: o.key, label: o.label })),
      ]
    : [];

  const renderCell = (column: Column<T, K>, row: T) => {
    const content = column.cell(row);
    if (rowHref && column === primary) {
      return (
        <Link
          to={rowHref(row)}
          className="text-ink hover:text-primary-ink font-medium hover:underline"
        >
          {content}
        </Link>
      );
    }
    return content;
  };

  const toggleSort = (key: K) => {
    if (!onSortChange) return;
    const direction: SortDirection = sort?.key === key && sort.direction === 'asc' ? 'desc' : 'asc';
    onSortChange({ key, direction });
  };

  return (
    <div className={className}>
      {/* md+ : real table */}
      <div className="hidden overflow-x-auto md:block">
        <table className="w-full border-collapse text-sm">
          <caption className="sr-only">{caption}</caption>
          <thead>
            <tr className="border-line bg-surface-2/60 border-b">
              {columns.map((column) => (
                <th
                  key={column.key}
                  scope="col"
                  aria-sort={column.sortable ? ariaSort(sort, column.key) : undefined}
                  className={cn(
                    'text-muted px-4 py-2.5 text-xs font-semibold tracking-wide uppercase',
                    alignClass[column.align ?? 'left'],
                    column.headerClassName,
                  )}
                >
                  {column.sortable && onSortChange ? (
                    <button
                      type="button"
                      onClick={() => toggleSort(column.key)}
                      className={cn(
                        'hover:text-ink inline-flex items-center gap-1 uppercase',
                        column.align === 'right' && 'flex-row-reverse',
                      )}
                    >
                      {column.header}
                      {sort?.key === column.key ? (
                        sort.direction === 'asc' ? (
                          <ArrowUp className="size-3.5" aria-hidden="true" />
                        ) : (
                          <ArrowDown className="size-3.5" aria-hidden="true" />
                        )
                      ) : (
                        <ArrowUpDown className="size-3.5 opacity-50" aria-hidden="true" />
                      )}
                    </button>
                  ) : (
                    column.header
                  )}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr
                key={getRowId(row)}
                onClick={
                  rowHref
                    ? (event) => {
                        const target = event.target as HTMLElement;
                        if (target.closest('a,button,input,select,textarea,label')) return;
                        void navigate(rowHref(row));
                      }
                    : undefined
                }
                className={cn(
                  'border-line border-b last:border-b-0',
                  rowHref && 'hover:bg-surface-2/70 cursor-pointer',
                )}
              >
                {columns.map((column) => (
                  <td
                    key={column.key}
                    className={cn(
                      'text-ink px-4 py-3 align-middle',
                      alignClass[column.align ?? 'left'],
                      column.className,
                    )}
                  >
                    {renderCell(column, row)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* < md : sort picker (the header buttons above are hidden) */}
      {onSortChange && sortOptions.length > 0 && (
        <div className="border-line flex items-center gap-2 border-b px-4 py-2 md:hidden">
          <Select
            aria-label={`Sort ${caption.toLowerCase()} by`}
            selectSize="sm"
            className="min-w-0 flex-1"
            value={sort?.key ?? ''}
            placeholder={sort ? undefined : 'Default order'}
            options={sortOptions}
            onChange={(event) => {
              const option = sortOptions.find((o) => o.value === event.target.value);
              if (option) onSortChange({ key: option.value, direction: sort?.direction ?? 'asc' });
            }}
          />
          <Button
            size="sm"
            variant="secondary"
            className="shrink-0"
            disabled={!sort}
            title="Reverse the order"
            leadingIcon={
              sort?.direction === 'desc' ? (
                <ArrowDown className="size-4" aria-hidden="true" />
              ) : (
                <ArrowUp className="size-4" aria-hidden="true" />
              )
            }
            onClick={() =>
              sort &&
              onSortChange({ key: sort.key, direction: sort.direction === 'asc' ? 'desc' : 'asc' })
            }
          >
            {sort?.direction === 'desc' ? 'Descending' : 'Ascending'}
          </Button>
        </div>
      )}

      {/* < md : stacked rows */}
      <ul className="divide-line divide-y md:hidden" aria-label={caption}>
        {rows.map((row) => (
          <li key={getRowId(row)} className="px-4 py-3">
            {primary && (
              <div className="text-ink text-sm font-medium">{renderCell(primary, row)}</div>
            )}
            <dl className="mt-1.5 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
              {columns
                .filter((column) => column !== primary && !column.hideOnMobile)
                .map((column) => (
                  <div key={column.key} className="contents">
                    <dt className="text-muted">{column.header}</dt>
                    <dd className="text-ink text-right">{column.cell(row)}</dd>
                  </div>
                ))}
            </dl>
          </li>
        ))}
      </ul>
    </div>
  );
}
