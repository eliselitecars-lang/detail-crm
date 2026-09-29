import { useRef, type ReactNode } from 'react';
import { brandStyle } from '@/components/layout/brand';
import { PRIVACY_PATH, TERMS_PATH } from '@/features/legal/paths';
import { publicPageTitle, useDocumentTitle } from '@/lib/useDocumentTitle';
import { useEmbedHeight, useTransparentBackground } from '../embed';

/**
 * Frame for a public page embedded in a shop's website (?embed=1), used
 * instead of PublicLayout: no header, transparent background, the legal
 * links open in a new tab (the app never renders them inside a frame).
 */
export function EmbedFrame({
  brandColor,
  title,
  shopName,
  children,
}: {
  brandColor?: string | null;
  /** As PublicLayout's `title` (the frame document's title). */
  title?: string | null;
  shopName?: string | null;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useDocumentTitle(publicPageTitle(title, shopName));
  useTransparentBackground();
  useEmbedHeight(ref);
  const link = 'hover:text-ink underline-offset-2 hover:underline';
  return (
    <div
      ref={ref}
      style={brandStyle(brandColor)}
      className="text-ink flex flex-col gap-3 p-3 sm:p-4"
    >
      <main className="w-full">{children}</main>
      <footer className="text-muted flex flex-wrap items-center justify-center gap-x-4 gap-y-1 text-xs">
        <span>Powered by Detail CRM</span>
        <a href={PRIVACY_PATH} target="_blank" rel="noopener noreferrer" className={link}>
          Privacy Policy
        </a>
        <a href={TERMS_PATH} target="_blank" rel="noopener noreferrer" className={link}>
          Terms of Service
        </a>
      </footer>
    </div>
  );
}
