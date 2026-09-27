import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { Card } from '@/components/ui';
import { cn } from '@/lib/cn';

export interface StatTileProps {
  label: string;
  value: ReactNode;
  /** Secondary line under the value. */
  detail?: ReactNode;
  /** "money" (amber) only for money figures. */
  tone?: 'default' | 'money' | 'danger';
  href?: string;
  icon?: ReactNode;
}

/** One headline number. Text stays in ink tokens; tone only tints money/overdue values. */
export function StatTile({ label, value, detail, tone = 'default', href, icon }: StatTileProps) {
  const body = (
    <>
      <div className="flex items-center justify-between gap-2">
        <p className="text-muted text-xs font-medium tracking-wide uppercase">{label}</p>
        {icon && (
          <span className="text-subtle [&_svg]:size-4" aria-hidden="true">
            {icon}
          </span>
        )}
      </div>
      <p
        className={cn(
          'tabular mt-1.5 text-xl font-semibold tracking-tight break-words sm:text-2xl',
          tone === 'money' ? 'text-money-ink' : tone === 'danger' ? 'text-danger-ink' : 'text-ink',
        )}
      >
        {value}
      </p>
      {detail && <p className="text-muted mt-1 text-xs">{detail}</p>}
    </>
  );
  return (
    <Card className="h-full">
      {href ? (
        <Link
          to={href}
          className="hover:bg-surface-2/60 rounded-card block h-full p-4 transition-colors focus-visible:outline-offset-[-2px]"
        >
          {body}
        </Link>
      ) : (
        <div className="p-4">{body}</div>
      )}
    </Card>
  );
}
