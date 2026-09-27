/** Leaves the app for an external URL (Stripe onboarding / dashboard). Mocked in tests. */
export function redirectTo(url: string): void {
  window.location.assign(url);
}
