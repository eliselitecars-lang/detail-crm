/**
 * Public runtime configuration. Only `VITE_`-prefixed variables reach the
 * browser, and only public values (Supabase URL + anon key) may live there.
 */
export interface PublicEnv {
  supabaseUrl: string;
  supabaseAnonKey: string;
}

function clean(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function isHttpUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:';
  } catch {
    return false;
  }
}

/** Returns the env when complete and well-formed, otherwise `null`. */
export function readPublicEnv(source: Record<string, unknown> = import.meta.env): PublicEnv | null {
  const supabaseUrl = clean(source.VITE_SUPABASE_URL);
  const supabaseAnonKey = clean(source.VITE_SUPABASE_ANON_KEY);
  if (!supabaseUrl || !supabaseAnonKey || !isHttpUrl(supabaseUrl)) return null;
  return { supabaseUrl: supabaseUrl.replace(/\/+$/, ''), supabaseAnonKey };
}

/** Which variables are missing/invalid — shown on the Setup screen. */
export function missingEnvVars(source: Record<string, unknown> = import.meta.env): string[] {
  const missing: string[] = [];
  const url = clean(source.VITE_SUPABASE_URL);
  if (!url || !isHttpUrl(url)) missing.push('VITE_SUPABASE_URL');
  if (!clean(source.VITE_SUPABASE_ANON_KEY)) missing.push('VITE_SUPABASE_ANON_KEY');
  return missing;
}
