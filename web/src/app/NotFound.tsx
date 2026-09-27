import { Compass } from 'lucide-react';
import { useEffect } from 'react';
import { Link } from 'react-router';
import { buttonClasses, EmptyState } from '@/components/ui';

export function NotFoundContent({
  homeTo = '/',
  homeLabel = 'Go home',
}: {
  homeTo?: string;
  homeLabel?: string;
}) {
  useEffect(() => {
    document.title = 'Page not found · Detail CRM';
  }, []);
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
