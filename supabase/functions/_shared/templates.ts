/**
 * Message template rendering. MUST stay byte-for-byte equivalent to the SQL
 * `render_template(body text, vars jsonb)` used for queued messages:
 *
 *  - A placeholder is `{{`, optional spaces/tabs, a name matching
 *    `[A-Za-z_][A-Za-z0-9_]*`, optional spaces/tabs, `}}`.
 *  - Names are case-sensitive. A known name is replaced by its value as text
 *    (strings verbatim, booleans `true`/`false`, numbers as plain decimals
 *    with no exponent - see `plainNumberText` - exactly as Postgres prints
 *    the jsonb number that JSON.stringify(vars) produces).
 *  - Unknown names and null/undefined values render as the empty string.
 *  - Rendering is a single pass: substituted values are never re-scanned, so a
 *    value containing `{{x}}` is emitted literally.
 *  - Anything that is not a well-formed placeholder (e.g. `{{ a b }}`, `{x}`)
 *    is left untouched.
 *
 * Vars are flat (string | number | boolean | null); nested objects are
 * rejected because their text form is not portable between JS and jsonb.
 *
 * Parity is defined over the JSON value: a JS number has no numeric scale, so
 * a SQL-built `1.50::numeric` renders "1.50" in SQL but arrives in JS as 1.5
 * and renders "1.5". Pass anything whose formatting matters (money, rates,
 * durations) as an already-formatted string.
 */

export type TemplateValue = string | number | boolean | null | undefined;
export type TemplateVars = Readonly<Record<string, TemplateValue>>;

const PLACEHOLDER = /\{\{[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\}\}/g;

/**
 * A finite number as Postgres prints the same value once it is jsonb: the
 * shortest round-trip digits (what JSON.stringify sends), but never in
 * exponent form, because jsonb numbers are `numeric` and numeric text output
 * is always plain decimal ("1e-7" -> "0.0000001", "1e+21" ->
 * "1000000000000000000000"). Numeric keeps exactly the input digits, so
 * expanding the exponent is all that is needed.
 */
export function plainNumberText(value: number): string {
  if (!Number.isFinite(value)) throw new RangeError("number must be finite");
  if (Object.is(value, -0)) return "0";
  const text = String(value);
  const match = /^(-?)(\d+)(?:\.(\d+))?e([+-]\d+)$/.exec(text);
  if (!match) return text;
  const [, sign = "", intPart = "", fracPart = "", expText = "0"] = match;
  const digits = intPart + fracPart;
  const point = intPart.length + Number(expText);
  if (point <= 0) return `${sign}0.${"0".repeat(-point)}${digits}`;
  if (point >= digits.length) return `${sign}${digits}${"0".repeat(point - digits.length)}`;
  return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`;
}

function valueToText(name: string, value: TemplateValue): string {
  if (value === null || value === undefined) return "";
  switch (typeof value) {
    case "string":
      return value;
    case "boolean":
      return value ? "true" : "false";
    case "number":
      if (!Number.isFinite(value)) {
        throw new TypeError(`template var "${name}" must be a finite number`);
      }
      return plainNumberText(value);
    default:
      throw new TypeError(`template var "${name}" must be a string, number, boolean or null`);
  }
}

export function renderTemplate(template: string, vars: TemplateVars): string {
  return template.replace(PLACEHOLDER, (_match, name: string) => {
    if (!Object.hasOwn(vars, name)) return "";
    return valueToText(name, vars[name]);
  });
}

/** Distinct placeholder names in order of first appearance. */
export function placeholdersIn(template: string): string[] {
  const seen = new Set<string>();
  for (const match of template.matchAll(PLACEHOLDER)) {
    const name = match[1];
    if (name !== undefined) seen.add(name);
  }
  return [...seen];
}

const HTML_ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

export function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (ch) => HTML_ESCAPES[ch] ?? ch);
}

/**
 * A bare http(s) URL in PLAIN text: runs until whitespace, a quote or an
 * angle bracket, and does not end in sentence punctuation. Matched against
 * the raw text (never the escaped HTML), so `"<link>"`, `<link>` or
 * `'<link>'` delimiters end the URL instead of leaking into it as
 * `&quot;` / `&gt;` / `&#39;` entity fragments.
 */
const URL_IN_TEXT = /https?:\/\/[^\s<>"']+[^\s<>"'.,;:!?)]/g;

/** One paragraph of plain text -> escaped HTML with its URLs linked. */
function linkifyEscaped(paragraph: string): string {
  let html = "";
  let last = 0;
  for (const match of paragraph.matchAll(URL_IN_TEXT)) {
    const start = match.index ?? 0;
    const url = escapeHtml(match[0]);
    html += `${escapeHtml(paragraph.slice(last, start))}<a href="${url}">${url}</a>`;
    last = start + match[0].length;
  }
  return html + escapeHtml(paragraph.slice(last));
}

/**
 * Plain-text message body → minimal, safe HTML for email: everything is
 * escaped, blank lines become paragraphs, single newlines become <br>, and
 * bare http(s) URLs become links (found in the text before escaping, then
 * escaped for both the href and the label).
 */
export function textToHtml(text: string): string {
  const normalized = text.replace(/\r\n?/g, "\n").trim();
  if (!normalized) return "";
  return normalized
    .split(/\n{2,}/)
    .map((paragraph) => `<p>${linkifyEscaped(paragraph).replace(/\n/g, "<br>")}</p>`)
    .join("\n");
}
