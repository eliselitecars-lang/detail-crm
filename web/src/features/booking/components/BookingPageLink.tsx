import type { AnchorHTMLAttributes } from 'react';

/**
 * A link INTO a shop's public booking page (/book/<slug>) from another page
 * (a booking, the portal, an expired private link). Always a full page load
 * without a referrer, never a router link: the booking page may load the
 * shop's Meta Pixel / GA4 tag (tracking.ts), and
 *  - in the same document, the tag's history listeners would report the page
 *    the customer goes back to (/booking/<token>, ?link=<token>, /portal);
 *  - with a referrer, the tag would receive the previous page's address,
 *    token included, as document.referrer.
 */
export function BookingPageLink({
  slug,
  children,
  ...rest
}: Omit<AnchorHTMLAttributes<HTMLAnchorElement>, 'href' | 'rel'> & { slug: string }) {
  return (
    <a href={`/book/${encodeURIComponent(slug)}`} rel="noreferrer" {...rest}>
      {children}
    </a>
  );
}
