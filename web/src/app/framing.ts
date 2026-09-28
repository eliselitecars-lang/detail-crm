/**
 * Framing rules (P-10). Only the public booking page (/book/<slug>) and lead
 * forms (/lead/<token>) may be embedded in a shop's own website; everything
 * else refuses to render inside a frame (RootLayout), whatever the hosting
 * headers say. Deploys that allow framing set WEB_EMBED_PATHS=/book/*,/lead/*
 * (docs/DEPLOY.md 4.3).
 */

const EMBEDDABLE = /^\/(book|lead)\/[^/]+\/?$/;

export function isEmbeddablePath(pathname: string): boolean {
  return EMBEDDABLE.test(pathname);
}

/** True inside any frame; a cross-origin parent that throws on access counts as framed. */
export function isFramed(win: Window = window): boolean {
  try {
    return win.top !== win.self;
  } catch {
    return true;
  }
}
