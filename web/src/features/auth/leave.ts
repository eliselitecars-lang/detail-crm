/**
 * Full page load of an in-app path, dropping every in-memory cache and
 * subscription (used after the account is deleted). Mocked in tests.
 */
export function reloadTo(path: string): void {
  window.location.replace(path);
}

/** /login?account=deleted: the sign-in page confirms the deletion. */
export const ACCOUNT_DELETED_LOGIN = '/login?account=deleted';
