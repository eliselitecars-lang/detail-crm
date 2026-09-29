import { Compass } from 'lucide-react';
import { Link } from 'react-router';
import { buttonClasses, EmptyState } from '@/components/ui';
import { appTitle, useDocumentTitle } from '@/lib/useDocumentTitle';

export function NotFoundContent({
  homeTo = '/',
  homeLabel = 'Go home',
}: {
  homeTo?: string;
  homeLabel?: string;
}) {
  useDocumentTitle(appTitle('Page not found'));
  return (
    <EmptyState
      icon={<Compass aria-hidden="true" />}
      title="Page not found"
      description="The page you’re looking for doesn’t exist or has moved."
      action={
        <Link to={homeTo} className={buttonClasses({ variant: 'secondary' })}>
          {homeLabel}
        </Link>
      }
    />
  );
}

/** Top-level 404. */
export default function NotFoundPage() {
  return (
    <div className="bg-canvas flex min-h-dvh items-center justify-center px-4">
      <NotFoundContent />
    </div>
  );
}

/** 404 inside the staff shell (keeps navigation). */
export function AppNotFoundPage() {
  return <NotFoundContent homeTo="/app" homeLabel="Back to dashboard" />;
}
