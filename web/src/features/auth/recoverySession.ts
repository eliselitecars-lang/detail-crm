import { isSupabaseConfigured, supabase } from '@/lib/supabase';

/**
 * Tracks whether this tab holds a password-RECOVERY session, i.e. the user
 * arrived through a valid reset link. /reset-password only offers its
 * no-current-password form in that case, never to an ordinary signed-in
 * session.
 *
 * supabase-js emits PASSWORD_RECOVERY exactly once, right after it parses
 * the link during client initialisation, which can be before React mounts
 * <AuthProvider>. So this module subscribes when it is first imported, in the
 * same tick the client is created. `checking` stays true until that
 * initialisation (and the event it schedules) has run.
 */
export interface RecoverySnapshot {
  /** Initialisation still running: the event may not have fired yet. */
  checking: boolean;
  /** A recovery link was redeemed in this tab and the password isn't changed yet. */
  active: boolean;
}

let snapshot: RecoverySnapshot = { checking: isSupabaseConfigured, active: false };
const listeners = new Set<() => void>();

function update(next: Partial<RecoverySnapshot>) {
  const merged = { ...snapshot, ...next };
  if (merged.checking === snapshot.checking && merged.active === snapshot.active) return;
  snapshot = merged;
  for (const listener of listeners) listener();
}

export function subscribeRecovery(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function getRecoverySnapshot(): RecoverySnapshot {
  return snapshot;
}

/** Call after the new password is saved: the link can't be reused in this tab. */
export function endPasswordRecovery(): void {
  update({ active: false });
}

if (isSupabaseConfigured && typeof window !== 'undefined') {
  supabase.auth.onAuthStateChange((event) => {
    if (event === 'PASSWORD_RECOVERY') update({ active: true });
    else if (event === 'SIGNED_OUT') update({ active: false });
  });
  const nextTask = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
  // initialize() is idempotent (returns the client's in-flight init). The
  // recovery event is dispatched from a timer queued during init, so wait for
  // the next task too before declaring the check finished.
  void Promise.resolve()
    .then(() => supabase.auth.initialize())
    .then(nextTask)
    .catch(() => undefined)
    .finally(() => update({ checking: false }));
}
