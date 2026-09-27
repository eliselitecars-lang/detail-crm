/**
 * Local copy of SQL `public.render_template(body, vars)` (migration 0032) and
 * `supabase/functions/_shared/templates.ts`, used for the live preview:
 *   - placeholder = "{{", optional spaces/tabs, name [A-Za-z_][A-Za-z0-9_]*,
 *     optional spaces/tabs, "}}"; names are case-sensitive
 *   - strings verbatim, numbers in JSON form (never exponent), booleans true/false
 *   - unknown names, null, objects and arrays render as ''
 *   - single pass: substituted values are never re-scanned
 *   - anything else (e.g. "{{ a b }}", "{x}") is left untouched
 */
export const PLACEHOLDER_RE = /\{\{[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\}\}/g;

export type TemplateVars = Readonly<Record<string, unknown>>;

function numberText(value: number): string {
  if (!Number.isFinite(value)) return '';
  const text = String(value);
  if (!/e/i.test(text)) return text;
  return value.toLocaleString('en-US', { useGrouping: false, maximumFractionDigits: 20 });
}

function valueText(value: unknown): string {
  if (typeof value === 'string') return value;
  if (typeof value === 'number') return numberText(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  return '';
}

export function renderTemplate(body: string, vars: TemplateVars): string {
  return body.replace(PLACEHOLDER_RE, (_match, name: string) =>
    Object.hasOwn(vars, name) ? valueText(vars[name]) : '',
  );
}

/** Placeholder names used in `body`, in order of first appearance. */
export function placeholdersIn(body: string): string[] {
  const names: string[] = [];
  for (const match of body.matchAll(PLACEHOLDER_RE)) {
    const name = match[1];
    if (name && !names.includes(name)) names.push(name);
  }
  return names;
}

/**
 * SMS segment estimate for the counter: GSM-7 text is 160 chars (153 per
 * part when split); anything outside GSM-7 (emoji, curly quotes…) is UCS-2 at
 * 70 (67 per part).
 */
const GSM7 =
  '@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà^{}\\[~]|€';

export function smsSegments(text: string): { segments: number; unicode: boolean } {
  if (text.length === 0) return { segments: 0, unicode: false };
  const unicode = [...text].some((ch) => !GSM7.includes(ch));
  const length = unicode ? [...text].length : text.length;
  const single = unicode ? 70 : 160;
  const part = unicode ? 67 : 153;
  return { segments: length <= single ? 1 : Math.ceil(length / part), unicode };
}
