import type { ReactNode } from 'react';
import { Navigate } from 'react-router';
import { ErrorState, LoadingState } from '@/components/ui';
import { useShopContext } from './shopContext';

/** Guarantees a current shop; sends users without one to onboarding. */
export function RequireShop({ children }: { children: ReactNode }) {
  const { status, error, refetch } = useShopContext();
  if (status === 'loading') return <LoadingState fullScreen label="Loading your shop…" />;
  if (status === 'error') {
    return (
      <div className="flex min-h-dvh items-center justify-center">
        <ErrorState error={error} title="Couldn’t load your shops" onRetry={() => void refetch()} />
      </div>
    );
  }
  if (status === 'empty') return <Navigate to="/app/onboarding" replace />;
  return <>{children}</>;
}
