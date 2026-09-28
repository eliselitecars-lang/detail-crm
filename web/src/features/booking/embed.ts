/**
 * Embed mode (P-10): /book/<slug>?embed=1 and /lead/<token>?embed=1 render
 * inside a shop's website (web/public/embed.js injects the iframe). No page
 * chrome, a transparent background, links that leave the page open in the
 * top window, and the content height posted to the parent so the frame
 * grows with it. Only the height, and a request to bring the frame's top
 * into view when the page moves to a new step, are ever posted (no data).
 */
import { useEffect, type RefObject } from 'react';
import { isFramed } from '@/app/framing';

export const EMBED_HEIGHT_MESSAGE = 'detailcrm:height';
export const EMBED_SCROLL_TOP_MESSAGE = 'detailcrm:scroll-top';

export function isEmbedMode(params: URLSearchParams): boolean {
  return params.get('embed') === '1';
}

/** Posts the element's height to the embedding page whenever it changes. */
export function useEmbedHeight(ref: RefObject<HTMLElement | null>, enabled = true): void {
  useEffect(() => {
    const el = ref.current;
    if (!enabled || !el || !isFramed()) return;
    let last = 0;
    const post = () => {
      const height = Math.ceil(el.getBoundingClientRect().height);
      if (height === last || height <= 0) return;
      last = height;
      window.parent.postMessage({ type: EMBED_HEIGHT_MESSAGE, height }, '*');
    };
    post();
    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', post);
      return () => window.removeEventListener('resize', post);
    }
    const observer = new ResizeObserver(post);
    observer.observe(el);
    return () => observer.disconnect();
  }, [ref, enabled]);
}

/**
 * The embedded page moved to a new step: the frame is sized to its content
 * and cannot scroll, so ask the embedding page (embed.js) to bring the
 * frame's top into view. A no-op outside a frame.
 */
export function requestEmbedScrollTop(): void {
  if (!isFramed()) {
    window.scrollTo({ top: 0 });
    return;
  }
  window.parent.postMessage({ type: EMBED_SCROLL_TOP_MESSAGE }, '*');
}

/** Makes the page background transparent while an embedded page is shown. */
export function useTransparentBackground(): void {
  useEffect(() => {
    const { documentElement: html, body } = document;
    const before = { html: html.style.background, body: body.style.background };
    html.style.background = 'transparent';
    body.style.background = 'transparent';
    return () => {
      html.style.background = before.html;
      body.style.background = before.body;
    };
  }, []);
}
