import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Database } from './database.types';
import { inspectStartupUrl } from './authUrlSession';
import { readPublicEnv } from './env';

export type TypedSupabaseClient = SupabaseClient<Database>;

const env = readPublicEnv();

/** False when VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY are missing. */
export const isSupabaseConfigured = env !== null;

function unconfiguredClient(): TypedSupabaseClient {
  // The app root renders <SetupScreen/> when not configured, so nothing should
  // reach this. If something does, fail loudly with a clear message instead of
  // a cryptic "cannot read property of undefined".
  return new Proxy({} as TypedSupabaseClient, {
    get(_target, prop) {
      if (prop === 'then') return undefined; // not a thenable
      throw new Error(
        `Supabase is not configured (tried to use supabase.${String(prop)}). ` +
          'Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY — see web/.env.example.',
      );
    },
  });
}

/** supabase-js' default storage key, kept explicitly so start-up can read it first. */
function sessionStorageKey(supabaseUrl: string): string {
  return `sb-${new URL(supabaseUrl).hostname.split('.')[0]}-auth-token`;
}

function createConfiguredClient(config: NonNullable<typeof env>): TypedSupabaseClient {
  const storageKey = sessionStorageKey(config.supabaseUrl);
  // Decided (and the address bar cleaned) before supabase-js reads the URL.
  const urlSession = inspectStartupUrl(storageKey);
  return createClient<Database>(config.supabaseUrl, config.supabaseAnonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      storageKey,
      // Implicit flow (a reset link works on another device than the one
      // that asked for it), but a session in the URL is accepted only for a
      // recovery link on /reset-password that belongs to the account signed
      // in here, or when nobody is (lib/authUrlSession.ts: login CSRF).
      // Sign-up confirmations land on /auth/callback, which asks first.
      detectSessionInUrl: () => urlSession.detect,
    },
    // TanStack Query owns the retry policy for reads (queryClient.ts:
    // bounded retries, none for permanent errors or while offline).
    // postgrest-js' own GET retries (1s + 2s + 4s after a network error)
    // stacked on top of that, so an offline page or the refetch after a
    // failed save took ~7s per attempt to report "Can't reach the server".
    db: { retry: false },
  });
}

/**
 * The one typed Supabase client. Import it only from feature `api.ts` files
 * and shared data hooks — never from presentational components.
 */
export const supabase: TypedSupabaseClient = env
  ? createConfiguredClient(env)
  : unconfiguredClient();

/** Public URL for an object in the public `shop-assets` bucket (logos, service images). */
export function shopAssetUrl(path: string | null | undefined): string | null {
  if (!path || !env) return null;
  return supabase.storage.from('shop-assets').getPublicUrl(path).data.publicUrl;
}
