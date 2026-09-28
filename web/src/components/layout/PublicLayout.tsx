import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { cn } from '@/lib/cn';
import { shopAssetUrl } from '@/lib/supabase';
import { brandStyle } from './brand';
import { formatPhone } from '@/lib/phone';
import { CUSTOMER_PORTAL_PATH } from '@/features/portal/paths';
import { LegalLinks } from './LegalLinks';

export interface PublicShopBranding {
  name: string;
  /** Storage path in the public `shop-assets` bucket (shops.logo_path). */
  logoPath?: string | null;
  /** "#RRGGBB" (shops.brand_color). */
  brandColor?: string | null;
  phone?: string | null;
  email?: string | null;
  website?: string | null;
}

export interface PublicLayoutProps {
  /** Shop branding from the page's public RPC; null while loading/unknown. */
  shop: PublicShopBranding | null;
  /**
   * Replaces the shop mark in the header (pages that belong to the service,
   * not to a shop: /privacy, /terms).
   */
  brand?: ReactNode;
  children: ReactNode;
  /** Narrow (documents/forms) or wide (booking wizard). */
  width?: 'narrow' | 'wide';
  className?: string;
  /**
   * The footer's legal links leave the document (full page loads) instead of
   * routing inside it: set while a shop's analytics tag is loaded on the page
   * (features/booking/tracking.ts), so the tag never sees another page.
   */
  fullPageLinks?: boolean;
  /**
   * The footer's "My account" link to the client portal (/portal: upcoming
   * visits, membership cancel / card update, documents, service reports,
   * referral credit). On by default for shop-branded pages; off on the
   * portal itself and on pages that belong to the service (`brand`).
   */
  accountLink?: boolean;
}

/**
 * Shop-branded frame for customer-facing pages (/book, /booking, /q, /i, /f,
 * /portal). Use the `brand` colour utilities (bg-brand text-brand-fg) inside
 * for shop-coloured accents; Amber stays reserved for pay buttons. The footer
 * links the operator's Privacy Policy and Terms of Service, and "My account"
 * (the client portal) so a customer can always find where they manage their
 * membership, card and documents.
 */
export function PublicLayout({
  shop,
  brand,
  children,
  width = 'narrow',
  className,
  fullPageLinks = false,
  accountLink,
}: PublicLayoutProps) {
  const logoUrl = shopAssetUrl(shop?.logoPath);
  const showAccountLink = accountLink ?? !brand;
  const footerLink = 'rounded-control hover:text-ink underline-offset-2 hover:underline';
  return (
    <div className="bg-canvas flex min-h-dvh flex-col" style={brandStyle(shop?.brandColor)}>
      <header className="border-line bg-surface border-b">
        <div
          className={cn(
            'mx-auto flex h-16 items-center gap-3 px-4',
            width === 'narrow' ? 'max-w-3xl' : 'max-w-5xl',
          )}
        >
          {brand ? (
            brand
          ) : shop ? (
            <>
              {logoUrl ? (
                <img src={logoUrl} alt="" className="h-9 w-auto max-w-32 rounded object-contain" />
              ) : (
                <span
                  aria-hidden="true"
                  className="rounded-control bg-brand text-brand-fg flex size-9 items-center justify-center text-sm font-semibold"
                >
                  {shop.name.charAt(0).toUpperCase()}
                </span>
              )}
              <span className="text-ink truncate text-base font-semibold">{shop.name}</span>
            </>
          ) : (
            <span className="bg-surface-3 h-5 w-40 animate-pulse rounded" aria-hidden="true" />
          )}
        </div>
      </header>
      <main
        className={cn(
          'mx-auto w-full flex-1 px-4 py-6 sm:py-10',
          width === 'narrow' ? 'max-w-3xl' : 'max-w-5xl',
          className,
        )}
      >
        {children}
      </main>
      <footer className="border-line border-t py-5">
        <div className="text-muted mx-auto flex max-w-5xl flex-wrap items-center justify-center gap-x-4 gap-y-2 px-4 text-xs">
          {shop?.phone && (
            <a href={`tel:${shop.phone}`} className="hover:text-ink">
              {formatPhone(shop.phone)}
            </a>
          )}
          {shop?.email && (
            <a href={`mailto:${shop.email}`} className="hover:text-ink">
              {shop.email}
            </a>
          )}
          {showAccountLink &&
            (fullPageLinks ? (
              <a href={CUSTOMER_PORTAL_PATH} className={footerLink}>
                My account
              </a>
            ) : (
              <Link to={CUSTOMER_PORTAL_PATH} className={footerLink}>
                My account
              </Link>
            ))}
          <span>Powered by Detail CRM</span>
          <LegalLinks fullPageLoad={fullPageLinks} />
        </div>
      </footer>
    </div>
  );
}
