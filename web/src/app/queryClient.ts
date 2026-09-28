import { MutationCache, onlineManager, QueryCache, QueryClient } from '@tanstack/react-query';
import { isNonRetryable, toAppError } from '@/lib/errors';

export interface QueryClientHooks {
  /** Called when any query/mutation fails because the session is no longer valid. */
  onSessionExpired?: () => void;
}

/**
 * Whether a failed query should be retried. Permission/validation/not-found
 * errors never are (retrying can't help), and neither is a network failure
 * while the browser reports it is offline: the page shows its error state
 * with Try again straight away, and `refetchOnReconnect` reloads it when the
 * connection comes back.
 */
export function shouldRetryQuery(failureCount: number, error: unknown): boolean {
  if (isNonRetryable(error)) return false;
  if (toAppError(error).kind === 'network' && !onlineManager.isOnline()) return false;
  return failureCount < 2;
}

/**
 * App-wide TanStack Query defaults:
 * - 30s staleTime (realtime + explicit invalidation keep data fresh),
 * - no retries for permission/validation/not-found errors (retrying can't help),
 * - mutations never retry (they are not guaranteed idempotent),
 * - networkMode 'always' for both: TanStack's default ('online') *pauses*
 *   work while the browser is offline, so a save spun forever inside a
 *   locked dialog and was then sent minutes later when the connection
 *   returned (a late "Record payment" / "Void invoice"), and a page with no
 *   cached data showed "Loading…" indefinitely. With 'always' the request is
 *   attempted and fails at once with the network error ("Can't reach the
 *   server…"), so dialogs unlock and show it, pages render ErrorState with
 *   Try again, and nothing is queued behind the user's back.
 */
export function createQueryClient({ onSessionExpired }: QueryClientHooks = {}): QueryClient {
  const handle = (error: unknown) => {
    if (toAppError(error).kind === 'session_expired') onSessionExpired?.();
  };
  return new QueryClient({
    queryCache: new QueryCache({ onError: handle }),
    mutationCache: new MutationCache({ onError: handle }),
    defaultOptions: {
      queries: {
        staleTime: 30_000,
        gcTime: 5 * 60_000,
        refetchOnWindowFocus: true,
        networkMode: 'always',
        retry: shouldRetryQuery,
      },
      mutations: { retry: false, networkMode: 'always' },
    },
  });
}
