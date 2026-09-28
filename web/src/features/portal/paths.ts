/**
 * The client portal (routes.tsx): upcoming visits, membership cancel / card
 * update, documents, service reports and referral credit. Signed-out visitors
 * are sent to /login?next=/portal first. Linked from every shop-branded public
 * page footer (PublicLayout) and from the membership join page.
 */
export const CUSTOMER_PORTAL_PATH = '/portal';

/**
 * Public page after a Stripe Checkout a staff member sent the customer
 * (card-setup and membership sign-up links: ?card= / ?membership=). The
 * payments function builds it as APP_BASE_URL/done/<shop slug>
 * (supabase/functions/_shared/links.ts checkoutDone).
 */
export const CHECKOUT_DONE_PATH = '/done/:slug';
