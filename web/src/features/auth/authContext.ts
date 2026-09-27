import type { Session, User } from '@supabase/supabase-js';
import { createContext, use } from 'react';

export type AuthStatus = 'loading' | 'signedIn' | 'signedOut';

export interface AuthContextValue {
  status: AuthStatus;
  session: Session | null;
  user: User | null;
  /**
   * True when this tab redeemed a valid password-reset link (PASSWORD_RECOVERY)
   * and hasn't set the new password yet. Gates /reset-password's form.
   */
  recovery: boolean;
  /** The client is still initialising, so `recovery` may still turn true. */
  recoveryChecking: boolean;
  signOut: () => Promise<void>;
}

export const AuthContext = createContext<AuthContextValue | null>(null);

/** Current session/user. Must be under <AuthProvider>. */
export function useAuth(): AuthContextValue {
  const ctx = use(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>');
  return ctx;
}
