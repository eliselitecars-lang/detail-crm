import type { Session } from '@supabase/supabase-js';
import { useQueryClient } from '@tanstack/react-query';
import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from 'react';
import { supabase } from '@/lib/supabase';
import { AuthContext, type AuthContextValue, type AuthStatus } from './authContext';
import { getRecoverySnapshot, subscribeRecovery } from './recoverySession';

/**
 * Single source of truth for the Supabase session. Subscribes once to
 * onAuthStateChange (which emits INITIAL_SESSION immediately) and clears the
 * query cache on sign-out so no tenant data survives across users.
 */
export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [status, setStatus] = useState<AuthStatus>('loading');
  const [session, setSession] = useState<Session | null>(null);
  const recovery = useSyncExternalStore(subscribeRecovery, getRecoverySnapshot);

  useEffect(() => {
    // NOTE: never await other supabase calls inside this callback — supabase-js
    // holds an auth lock while it runs.
    const { data } = supabase.auth.onAuthStateChange((event, nextSession) => {
      if (event === 'SIGNED_OUT') queryClient.clear();
      setSession(nextSession);
      setStatus(nextSession ? 'signedIn' : 'signedOut');
    });
    return () => data.subscription.unsubscribe();
  }, [queryClient]);

  const signOut = useCallback(async () => {
    const { error } = await supabase.auth.signOut();
    if (error) {
      // Server-side revoke failed (offline, expired): still drop the local session.
      await supabase.auth.signOut({ scope: 'local' });
    }
    queryClient.clear();
  }, [queryClient]);

  const value = useMemo<AuthContextValue>(
    () => ({
      status,
      session,
      user: session?.user ?? null,
      recovery: recovery.active,
      recoveryChecking: recovery.checking,
      signOut,
    }),
    [status, session, recovery, signOut],
  );

  return <AuthContext value={value}>{children}</AuthContext>;
}
