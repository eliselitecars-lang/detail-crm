import type { AnchorHTMLAttributes } from 'react';
import { Link } from 'react-router';
import { useTrackingActive } from '../tracking';

/**
 * An in-app link on the public booking pages. While a shop's tag is loaded
 * in this document it is a plain link (a full page load), so the tag's
 * history listeners never see the next URL: booking, invoice and form links
 * carry the customer's token (tracking.ts). Otherwise a router link.
 */
export function PublicLink({
  to,
  children,
  ...rest
}: AnchorHTMLAttributes<HTMLAnchorElement> & { to: string }) {
  const tracking = useTrackingActive();
  if (tracking) {
    return (
      <a href={to} {...rest}>
        {children}
      </a>
    );
  }
  return (
    <Link to={to} {...rest}>
      {children}
    </Link>
  );
}
