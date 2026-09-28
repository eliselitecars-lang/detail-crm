import { onlineManager } from '@tanstack/react-query';
import { WifiOff } from 'lucide-react';
import { useSyncExternalStore } from 'react';

const subscribe = (onChange: () => void) => onlineManager.subscribe(onChange);
const getOnline = () => onlineManager.isOnline();

/**
 * A small fixed notice while the browser reports it is offline, on every
 * page (staff app, portal, public booking). Saves are not queued: each one
 * fails with "Can't reach the server…" (see queryClient.ts), and this says
 * why before the user tries.
 */
export function OfflineBanner() {
  const online = useSyncExternalStore(subscribe, getOnline, () => true);
  return (
    <div role="status" aria-live="polite" className="contents">
      {online ? null : (
        <div className="pointer-events-none fixed inset-x-0 top-0 z-[70] flex justify-center p-2">
          <p className="border-line bg-surface text-ink shadow-pop inline-flex max-w-full items-center gap-2 rounded-full border px-3 py-1.5 text-sm font-medium">
            <WifiOff className="text-warning-ink size-4 shrink-0" aria-hidden="true" />
            You’re offline. Changes can’t be saved until your connection is back.
          </p>
        </div>
      )}
    </div>
  );
}
