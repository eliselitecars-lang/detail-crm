import { ChevronLeft, ChevronRight } from 'lucide-react';
import { cn } from '@/lib/cn';
import { Button } from './Button';

export interface PaginationProps {
  /** 1-based page. */
  page: number;
  pageSize: number;
  /** Total rows (from PostgREST `count: 'exact'`). */
  total: number;
  onPageChange: (page: number) => void;
  className?: string;
}

/** Range for PostgREST `.range(from, to)` (inclusive) for a 1-based page. */
export function pageRange(page: number, pageSize: number): { from: number; to: number } {
  const from = (Math.max(1, page) - 1) * pageSize;
  return { from, to: from + pageSize - 1 };
}

export function Pagination({ page, pageSize, total, onPageChange, className }: PaginationProps) {
  const pageCount = Math.max(1, Math.ceil(total / pageSize));
  const first = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const last = Math.min(total, page * pageSize);
  return (
    <nav
      aria-label="Pagination"
      className={cn(
        'text-muted flex items-center justify-between gap-3 px-4 py-3 text-sm',
        className,
      )}
    >
      <p className="tabular" aria-live="polite">
        {total === 0
          ? 'No results'
          : `Showing ${first}–${last} of ${total.toLocaleString('en-US')}`}
      </p>
      <div className="flex items-center gap-2">
        <Button
          variant="secondary"
          size="sm"
          leadingIcon={<ChevronLeft className="size-4" aria-hidden="true" />}
          disabled={page <= 1}
          onClick={() => onPageChange(page - 1)}
        >
          Previous
        </Button>
        <Button
          variant="secondary"
          size="sm"
          trailingIcon={<ChevronRight className="size-4" aria-hidden="true" />}
          disabled={page >= pageCount}
          onClick={() => onPageChange(page + 1)}
        >
          Next
        </Button>
      </div>
    </nav>
  );
}
