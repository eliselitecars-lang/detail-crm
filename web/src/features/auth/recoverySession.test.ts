import { afterEach, describe, expect, it, vi } from 'vitest';

type Listener = (event: string) => void;

/** Loads a fresh copy of the module against a controllable fake client. */
async function load({ configured = true } = {}) {
  vi.resetModules();
  const listeners: Listener[] = [];
  let finishInit: () => void = () => undefined;
  const auth = {
    onAuthStateChange: vi.fn((listener: Listener) => {
      listeners.push(listener);
      return { data: { subscription: { unsubscribe: vi.fn() } } };
    }),
    initialize: vi.fn(
      () =>
        new Promise<{ error: null }>((resolve) => {
          finishInit = () => resolve({ error: null });
        }),
    ),
  };
  vi.doMock('@/lib/supabase', () => ({ isSupabaseConfigured: configured, supabase: { auth } }));
  const mod = await import('./recoverySession');
  const emit = (event: string) => listeners.forEach((listener) => listener(event));
  return { mod, auth, emit, finishInit: () => finishInit() };
}

afterEach(() => {
  vi.doUnmock('@/lib/supabase');
  vi.resetModules();
});

describe('recoverySession', () => {
  it('subscribes as soon as it is imported, before any React tree mounts', async () => {
    const { auth, mod } = await load();
    expect(auth.onAuthStateChange).toHaveBeenCalledTimes(1);
    expect(mod.getRecoverySnapshot()).toEqual({ checking: true, active: false });
  });

  it('stays "checking" until client initialisation and its queued events have run', async () => {
    const { mod, emit, finishInit } = await load();
    const onChange = vi.fn();
    mod.subscribeRecovery(onChange);
    await Promise.resolve();
    expect(mod.getRecoverySnapshot().checking).toBe(true);

    finishInit();
    // supabase-js dispatches PASSWORD_RECOVERY from a timer queued during init.
    setTimeout(() => emit('PASSWORD_RECOVERY'), 0);
    await vi.waitFor(() => expect(mod.getRecoverySnapshot().checking).toBe(false));
    expect(mod.getRecoverySnapshot().active).toBe(true);
    expect(onChange).toHaveBeenCalled();
  });

  it('only a PASSWORD_RECOVERY event activates it; sign-out and completion end it', async () => {
    const { mod, emit } = await load();
    emit('SIGNED_IN');
    emit('INITIAL_SESSION');
    expect(mod.getRecoverySnapshot().active).toBe(false);

    emit('PASSWORD_RECOVERY');
    expect(mod.getRecoverySnapshot().active).toBe(true);
    emit('TOKEN_REFRESHED');
    expect(mod.getRecoverySnapshot().active).toBe(true);
    emit('SIGNED_OUT');
    expect(mod.getRecoverySnapshot().active).toBe(false);

    emit('PASSWORD_RECOVERY');
    mod.endPasswordRecovery();
    expect(mod.getRecoverySnapshot().active).toBe(false);
  });

  it('does nothing when Supabase is not configured', async () => {
    const { mod, auth } = await load({ configured: false });
    expect(auth.onAuthStateChange).not.toHaveBeenCalled();
    expect(mod.getRecoverySnapshot()).toEqual({ checking: false, active: false });
  });
});
