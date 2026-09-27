import { MutationCache, QueryCache, QueryClient } from '@tanstack/react-query';
import { isNonRetryable, toAppError } from '@/lib/errors';

export interface QueryClientHooks {
  /** Called when any query/mutation fails because the session is no longer valid. */
  onSessionExpired?: () => void;
}

/**
 * App-wide TanStack Query defaults:
 * - 30s staleTime (realtime + explicit invalidation keep data fresh),
 * - no retries for permission/validation/not-found errors (retrying can't help),
 * - mutations never retry (they are not guaranteed idempotent).
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
        retry: (failureCount, error) => !isNonRetryable(error) && failureCount < 2,
      },
      mutations: { retry: false },
    },
  });
}
