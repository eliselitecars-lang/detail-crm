import type { ReactNode } from 'react';
import { Navigate, useLocation } from 'react-router';
import { LoadingState } from '@/components/ui';
import { useAuth } from './authContext';
import { loginPath } from './redirects';

/** Renders children only for a signed-in user; otherwise redirects to /login?next=… */
export function RequireAuth({ children }: { children: ReactNode }) {
  const { status } = useAuth();
  const location = useLocation();
  if (status === 'loading') return <LoadingState fullScreen label="Signing you in…" />;
  if (status === 'signedOut') {
    return (
      <Navigate to={loginPath(`${location.pathname}${location.search}${location.hash}`)} replace />
    );
  }
  return <>{children}</>;
}
