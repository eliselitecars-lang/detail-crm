import { isEmbeddablePath } from './framing';

/**
 * Theme of a page embedded in a shop's website (/book/<slug>?embed=1,
 * /lead/<token>?embed=1). The embed has a transparent background so it
 * blends into the shop's page, so it must not follow the visitor's device
 * theme or saved preference: dark text tokens on a light shop page (or a
 * dark `color-scheme` that makes the browser paint an opaque canvas behind
 * the frame) is unreadable. Light unless the snippet asks otherwise
 * (embed.js data-theme="dark" | "auto" → &theme=): "auto" follows the
 * visitor's device, for shop sites that switch themselves.
 *
 * Mirrored by the boot script in index.html (keep in sync).
 */
export type EmbedTheme = 'light' | 'dark' | 'auto';

export function embedThemeFor(pathname: string, search: string): EmbedTheme | null {
  const params = new URLSearchParams(search);
  if (params.get('embed') !== '1' || !isEmbeddablePath(pathname)) return null;
  const theme = params.get('theme');
  return theme === 'dark' || theme === 'auto' ? theme : 'light';
}
