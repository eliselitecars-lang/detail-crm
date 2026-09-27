import { Outlet, ScrollRestoration } from 'react-router';
import { LoadingState } from '@/components/ui';

export function RootLayout() {
  return (
    <>
      <ScrollRestoration />
      <Outlet />
    </>
  );
}

/** Shown while the first lazy route module loads. */
export function BootScreen() {
  return <LoadingState fullScreen label="Loading Detail CRM…" />;
}
