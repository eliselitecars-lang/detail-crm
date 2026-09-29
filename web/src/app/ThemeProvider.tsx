import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from 'react';
import { readLocal, storageKeys, writeLocal } from '@/lib/storage';
import { embedThemeFor } from './embedTheme';
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

/**
 * Light/dark theme via `data-theme` on <html> (see index.html boot script).
 * A page embedded in a shop's website takes the embed's theme instead
 * (embedTheme.ts: light unless the snippet asks for dark / auto).
 */
export function ThemeProvider({ children }: { children: ReactNode }) {
  const [preference, setPreferenceState] = useState<ThemePreference>(readPreference);
  // Fixed for the document's life: an embedded page never leaves its frame.
  const [embedTheme] = useState(() =>
    embedThemeFor(window.location.pathname, window.location.search),
  );
  const systemDark = useSyncExternalStore(subscribeSystem, systemPrefersDark, () => false);
  const effective =
    embedTheme === null ? preference : embedTheme === 'auto' ? 'system' : embedTheme;
  const resolved = effective === 'system' ? (systemDark ? 'dark' : 'light') : effective;

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
