/**
 * Embed snippets for shop websites (P-10). The script is web/public/embed.js
 * (no dependencies): it finds `<div data-detailcrm-book="<slug>">` (optional
 * data-link / data-lead), injects the iframe (`?embed=1` compact layout) and
 * resizes it from the page's height messages. The plain iframe works without
 * the script (fixed height). Only /book/* and /lead/* may be framed.
 */

function escapeAttr(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

export interface EmbedTarget {
  slug: string;
  /** Private booking link token (?link=). */
  linkToken?: string | undefined;
  /** Lead form token (/lead/<token>). */
  leadToken?: string | undefined;
}

/** The page the iframe shows. */
export function embedPageUrl(target: EmbedTarget, origin: string = window.location.origin): string {
  if (target.leadToken) return `${origin}/lead/${encodeURIComponent(target.leadToken)}?embed=1`;
  const base = `${origin}/book/${encodeURIComponent(target.slug)}?embed=1`;
  return target.linkToken ? `${base}&link=${encodeURIComponent(target.linkToken)}` : base;
}

/** Script snippet: auto-height iframe through embed.js. */
export function embedScriptSnippet(
  target: EmbedTarget,
  origin: string = window.location.origin,
): string {
  const attrs = [`data-detailcrm-book="${escapeAttr(target.slug)}"`];
  if (target.linkToken) attrs.push(`data-link="${escapeAttr(target.linkToken)}"`);
  if (target.leadToken) attrs.push(`data-lead="${escapeAttr(target.leadToken)}"`);
  return `<div ${attrs.join(' ')}></div>\n<script src="${escapeAttr(`${origin}/embed.js`)}" async></script>`;
}

/** Plain iframe snippet (fixed height; no script needed). */
export function embedIframeSnippet(
  target: EmbedTarget,
  title: string,
  origin: string = window.location.origin,
): string {
  // color-scheme:light matches the (light, transparent) embedded page, so a
  // dark website never gets an opaque canvas behind the frame.
  return `<iframe src="${escapeAttr(embedPageUrl(target, origin))}" title="${escapeAttr(title)}" style="width:100%;min-height:720px;border:0;color-scheme:light" loading="lazy"></iframe>`;
}
