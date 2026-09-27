import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from 'react';
import { readLocal, storageKeys, writeLocal } from '@/lib/storage';
import { ThemeContext, type ThemeContextValue, type ThemePreference } from './themeContext';

const QUERY = '(prefers-color-scheme: dark)';

function subscribeSystem(callback: () => void) {
  if (typeof window.matchMedia !== 'function') return () => undefined;
  const mql = window.matchMedia(QUERY);
  mql.addEventListener('change', callback);
  return () => mql.removeEventListener('change', callback);
}

function systemPrefersDark(): boolean {
  return typeof window.matchMedia === 'function' && window.matchMedia(QUERY).matches;
}

function readPreference(): ThemePreference {
  const stored = readLocal(storageKeys.theme);
  return stored === 'light' || stored === 'dark' || stored === 'system' ? stored : 'system';
}

/** Light/dark theme via `data-theme` on <html> (see index.html boot script). */
export function ThemeProvider({ children }: { children: ReactNode }) {
  const [preference, setPreferenceState] = useState<ThemePreference>(readPreference);
  const systemDark = useSyncExternalStore(subscribeSystem, systemPrefersDark, () => false);
  const resolved = preference === 'system' ? (systemDark ? 'dark' : 'light') : preference;

  useEffect(() => {
    document.documentElement.dataset.theme = resolved;
  }, [resolved]);

  const setPreference = useCallback((next: ThemePreference) => {
    setPreferenceState(next);
    writeLocal(storageKeys.theme, next);
  }, []);

  const value = useMemo<ThemeContextValue>(
    () => ({ preference, resolved, setPreference }),
    [preference, resolved, setPreference],
  );
  return <ThemeContext value={value}>{children}</ThemeContext>;
}
