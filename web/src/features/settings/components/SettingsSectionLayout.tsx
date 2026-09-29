import { Eye } from 'lucide-react';
import type { ReactNode } from 'react';
import type { UseQueryResult } from '@tanstack/react-query';
import { Card, ErrorState, LoadingState } from '@/components/ui';
import { appTitle, useDocumentTitle } from '@/lib/useDocumentTitle';
import { sectionByPath, type SettingsSectionPath } from '../sections';

export interface SettingsSectionLayoutProps {
  section: SettingsSectionPath;
  /** Buttons next to the heading (e.g. "Add coupon"). */
  actions?: ReactNode;
  /** Shows the read-only banner (managers viewing owner/admin settings). */
  readOnly?: boolean;
  children: ReactNode;
}

/** Heading + description for one settings sub-page. */
export function SettingsSectionLayout({
  section,
  actions,
  readOnly = false,
  children,
}: SettingsSectionLayoutProps) {
  const meta = sectionByPath(section);
  useDocumentTitle(appTitle(`${meta.label} · Settings`));
  return (
    <div className="flex min-w-0 flex-col gap-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-ink text-lg font-semibold tracking-tight">{meta.label}</h2>
          <p className="text-muted mt-0.5 text-sm">{meta.description}</p>
        </div>
        {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
      </div>
      {readOnly && <ReadOnlyNotice />}
      {children}
    </div>
  );
}

export function ReadOnlyNotice() {
  return (
    <p
      role="note"
      className="rounded-card border-line bg-surface-2 text-muted flex items-center gap-2 border px-3 py-2 text-sm"
    >
      <Eye className="size-4 shrink-0" aria-hidden="true" />
      You can view these settings. Only the owner or an admin can change them.
    </p>
  );
}

/**
 * Renders loading / error (with retry) for a query, then `children(data)`.
 * The empty state is the child's job (lists know what "empty" means).
 */
export function QueryView<T>({
  query,
  label,
  children,
}: {
  query: UseQueryResult<T>;
  label: string;
  children: (data: T) => ReactNode;
}) {
  if (query.isPending) {
    return (
      <Card>
        <LoadingState label={`Loading ${label}…`} />
      </Card>
    );
  }
  if (query.isError) {
    return (
      <Card>
        <ErrorState
          title={`Couldn’t load ${label}`}
          error={query.error}
          onRetry={() => void query.refetch()}
          retrying={query.isRefetching}
        />
      </Card>
    );
  }
  return <>{children(query.data)}</>;
}
