import { useEffect } from 'react';

/** The browser tab title when no page names itself (index.html has the same). */
export const APP_TITLE = 'Detail CRM';

/** "<page> · Detail CRM" for pages that belong to the service. */
export function appTitle(page: string): string {
  return `${page} · ${APP_TITLE}`;
}

/**
 * Tab title of a public page: "<page> · <shop>" ("Quote #1001 · Glacier
 * Detailing"), the shop name alone without a page title, and the service
 * name while no shop is known (loading, errors, /privacy, /pricing).
 */
export function publicPageTitle(
  title: string | null | undefined,
  shopName?: string | null,
): string {
  const owner = shopName?.trim() || APP_TITLE;
  const page = title?.trim();
  return page && page !== owner ? `${page} · ${owner}` : owner;
}

/**
 * Titles currently claimed by mounted components, in the order they were
 * set. The latest one is shown; when its component unmounts (or its title
 * changes) the previous claim comes back, and with none left the tab reads
 * APP_TITLE again. So leaving a page never leaves its title behind: signing
 * out from a customer's page does not keep that customer's name on the
 * sign-in tab (WCAG 2.4.2).
 */
const claims: { title: string }[] = [];

function apply(): void {
  document.title = claims.at(-1)?.title ?? APP_TITLE;
}

/**
 * Sets document.title while the calling component is mounted. `null` /
 * empty claims nothing (the title shown stays whatever else claimed one).
 */
export function useDocumentTitle(title: string | null | undefined): void {
  useEffect(() => {
    if (!title) return undefined;
    const claim = { title };
    claims.push(claim);
    apply();
    return () => {
      const index = claims.indexOf(claim);
      if (index >= 0) claims.splice(index, 1);
      apply();
    };
  }, [title]);
}
