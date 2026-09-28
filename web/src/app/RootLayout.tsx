import { ExternalLink, ShieldAlert } from 'lucide-react';
import { Outlet, ScrollRestoration, useLocation } from 'react-router';
import { LoadingState } from '@/components/ui';
import { isEmbeddablePath, isFramed } from './framing';
import { OfflineBanner } from './OfflineBanner';

export function RootLayout() {
  const { pathname } = useLocation();
  // Clickjacking defence that works on any host: only the booking and lead
  // form pages may render inside another site's frame (the deploy headers
  // say the same with frame-ancestors / X-Frame-Options where supported).
  if (isFramed() && !isEmbeddablePath(pathname)) return <FramedNotice />;
  return (
    <>
      <ScrollRestoration />
      <OfflineBanner />
      <Outlet />
    </>
  );
}

/** Shown instead of any non-embeddable page loaded inside a frame. */
function FramedNotice() {
  return (
    <main className="bg-canvas flex min-h-dvh items-center justify-center p-6">
      <div className="rounded-card border-line bg-surface flex max-w-sm flex-col items-center gap-3 border p-6 text-center">
        <ShieldAlert className="text-muted size-8" aria-hidden="true" />
        <h1 className="text-ink text-base font-semibold">This page can’t be shown here</h1>
        <p className="text-muted text-sm">
          For your security, this page only opens in its own browser tab.
        </p>
        <a
          href={window.location.href}
          target="_blank"
          rel="noopener noreferrer"
          className="text-primary-ink inline-flex items-center gap-1.5 text-sm font-medium hover:underline"
        >
          Open in a new tab
          <ExternalLink className="size-4" aria-hidden="true" />
        </a>
      </div>
    </main>
  );
}

/** Shown while the first lazy route module loads. */
export function BootScreen() {
  return <LoadingState fullScreen label="Loading Detail CRM…" />;
}
