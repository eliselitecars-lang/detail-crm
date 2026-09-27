import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Database } from './database.types';
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

/**
 * The one typed Supabase client. Import it only from feature `api.ts` files
 * and shared data hooks — never from presentational components.
 */
export const supabase: TypedSupabaseClient = env
  ? createClient<Database>(env.supabaseUrl, env.supabaseAnonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        // Handles email confirmation, magic links, invites and password
        // recovery links (implicit flow: works when the link is opened on a
        // different device than the one that requested it).
        detectSessionInUrl: true,
      },
    })
  : unconfiguredClient();

/** Public URL for an object in the public `shop-assets` bucket (logos, service images). */
export function shopAssetUrl(path: string | null | undefined): string | null {
  if (!path || !env) return null;
  return supabase.storage.from('shop-assets').getPublicUrl(path).data.publicUrl;
}
