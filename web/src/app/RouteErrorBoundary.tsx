import { RefreshCw } from 'lucide-react';
import { isRouteErrorResponse, Link, useRouteError } from 'react-router';
import { Button, buttonClasses, ErrorState } from '@/components/ui';
import { NotFoundContent } from './NotFound';

function isChunkLoadError(error: unknown): boolean {
  return (
    error instanceof Error &&
    /dynamically imported module|importing a module script failed|error loading dynamically|chunkloaderror/i.test(
      `${error.name} ${error.message}`,
    )
  );
}

/**
 * errorElement for every route: 404s, stale-deploy chunk failures and
 * unexpected render errors — the rest of the app keeps working.
 */
export function RouteErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error) && error.status === 404) {
    return (
      <div className="flex min-h-[60vh] items-center justify-center">
        <NotFoundContent />
      </div>
    );
  }

  if (isChunkLoadError(error)) {
    return (
      <div className="flex min-h-[60vh] flex-col items-center justify-center gap-3 px-4 text-center">
        <p className="text-ink text-sm font-semibold">A new version of Detail CRM is available</p>
        <p className="text-muted text-sm">Reload to continue.</p>
        <Button
          leadingIcon={<RefreshCw className="size-4" aria-hidden="true" />}
          onClick={() => window.location.reload()}
        >
          Reload
        </Button>
      </div>
    );
  }

  if (import.meta.env.DEV) console.error(error);

  return (
    <div className="flex min-h-[60vh] flex-col items-center justify-center">
      <ErrorState
        title="Something went wrong on this page"
        error={isRouteErrorResponse(error) ? new Error(error.statusText) : error}
        onRetry={() => window.location.reload()}
      />
      <Link to="/app" className={buttonClasses({ variant: 'ghost', size: 'sm' })}>
        Go to dashboard
      </Link>
    </div>
  );
}
