/**
 * localStorage wrappers that never throw (private mode, quota, disabled
 * storage). Use only for per-browser conveniences (last shop, theme).
 */
export function readLocal(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function writeLocal(key: string, value: string | null): void {
  try {
    if (value === null) window.localStorage.removeItem(key);
    else window.localStorage.setItem(key, value);
  } catch {
    // ignore — storage is a convenience only
  }
}

export const storageKeys = {
  theme: 'detailcrm:theme',
  lastShop: (userId: string) => `detailcrm:lastShop:${userId}`,
  sidebarCollapsed: 'detailcrm:sidebarCollapsed',
} as const;
