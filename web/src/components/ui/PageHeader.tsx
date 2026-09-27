import { ChevronLeft } from 'lucide-react';
import { useEffect, type ReactNode } from 'react';
import { Link } from 'react-router';
import { cn } from '@/lib/cn';

export interface PageHeaderProps {
  title: string;
  description?: ReactNode;
  /** Buttons on the right (wrap below the title on small screens). */
  actions?: ReactNode;
  /** Back link shown above the title. */
  back?: { to: string; label: string };
  /** Badges etc. next to the title. */
  meta?: ReactNode;
  /** Sets document.title to "<title> · Detail CRM" (default true). */
  setDocumentTitle?: boolean;
  className?: string;
}

export function PageHeader({
  title,
  description,
  actions,
  back,
  meta,
  setDocumentTitle = true,
  className,
}: PageHeaderProps) {
  useEffect(() => {
    if (setDocumentTitle) document.title = `${title} · Detail CRM`;
  }, [title, setDocumentTitle]);

  return (
    <header className={cn('mb-5 flex flex-col gap-3 sm:mb-6', className)}>
      {back && (
        <Link
          to={back.to}
          className="text-muted hover:text-ink inline-flex w-fit items-center gap-1 text-sm font-medium"
        >
          <ChevronLeft className="size-4" aria-hidden="true" />
          {back.label}
        </Link>
      )}
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-ink text-xl font-semibold tracking-tight sm:text-2xl">{title}</h1>
            {meta}
          </div>
          {description && <p className="text-muted mt-1 text-sm">{description}</p>}
        </div>
        {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
      </div>
    </header>
  );
}
