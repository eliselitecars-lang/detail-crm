import { Download } from 'lucide-react';
import type { ReactNode } from 'react';
import { Button, ErrorState, LoadingState } from '@/components/ui';
import { downloadCsv } from '../csv';

export interface StatTileProps {
  label: string;
  value: ReactNode;
  hint?: ReactNode;
}

export function StatTile({ label, value, hint }: StatTileProps) {
  return (
    <div className="rounded-card border-line bg-surface shadow-card flex min-w-0 flex-col gap-1 border p-4">
      <dt className="text-muted text-xs font-medium">{label}</dt>
      <dd className="tabular text-ink truncate text-xl font-semibold">{value}</dd>
      {hint && <dd className="text-muted text-xs">{hint}</dd>}
    </div>
  );
}

export function StatGrid({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div role="group" aria-label={label}>
      <dl className="grid grid-cols-2 gap-3 lg:grid-cols-4">{children}</dl>
    </div>
  );
}

interface QueryLike {
  isPending: boolean;
  error: unknown;
  isRefetching: boolean;
  refetch: () => Promise<unknown>;
}

/** Loading / error (with retry) wrapper; renders children once data is ready. */
export function ReportState({
  query,
  title,
  children,
}: {
  query: QueryLike;
  title: string;
  children: () => ReactNode;
}) {
  if (query.isPending) return <LoadingState label={`Loading ${title.toLowerCase()}…`} />;
  if (query.error)
    return (
      <ErrorState
        error={query.error}
        title={`Couldn’t load ${title.toLowerCase()}`}
        onRetry={() => void query.refetch()}
        retrying={query.isRefetching}
      />
    );
  return <>{children()}</>;
}

export function CsvButton({
  filename,
  build,
  disabled,
  label = 'Export CSV',
}: {
  filename: string;
  build: () => string;
  disabled?: boolean;
  label?: string;
}) {
  return (
    <Button
      variant="secondary"
      size="sm"
      leadingIcon={<Download />}
      disabled={disabled}
      onClick={() => downloadCsv(filename, build())}
    >
      {label}
    </Button>
  );
}
