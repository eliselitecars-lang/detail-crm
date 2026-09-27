/**
 * A deliberately tiny, SAFE markdown renderer for shop-authored form bodies
 * (waivers, terms). It never produces raw HTML: the text is parsed into a
 * small block/inline tree and rendered as React elements, so every character
 * is escaped by React. Supported: #–###### headings, paragraphs (single line
 * breaks kept), **bold** / __bold__, *italic* / _italic_, "-", "*", "+"
 * bullet lists and "1." numbered lists. Everything else (links, images,
 * HTML tags, tables) shows as the literal text.
 */

export type MdInline =
  | { type: 'text'; text: string }
  | { type: 'strong'; children: MdInline[] }
  | { type: 'em'; children: MdInline[] };

export type MdBlock =
  | { type: 'heading'; level: 1 | 2 | 3 | 4 | 5 | 6; children: MdInline[] }
  | { type: 'paragraph'; lines: MdInline[][] }
  | { type: 'list'; ordered: boolean; start: number; items: MdInline[][] };

const HEADING_RE = /^(#{1,6})\s+(.*?)\s*#*\s*$/;
const BULLET_RE = /^\s*[-*+]\s+(.*)$/;
const ORDERED_RE = /^\s*(\d{1,9})[.)]\s+(.*)$/;

// Order matters: bold before italic so "**x**" is not read as two italics.
const INLINE_RE =
  /\*\*(?=\S)([\s\S]*?\S)\*\*|__(?=\S)([\s\S]*?\S)__|\*(?=\S)([\s\S]*?\S)\*|(?<![A-Za-z0-9])_(?=\S)([\s\S]*?\S)_(?![A-Za-z0-9])/;

export function parseInline(text: string, depth = 0): MdInline[] {
  const out: MdInline[] = [];
  let rest = text;
  while (rest.length > 0) {
    const match = depth < 4 ? INLINE_RE.exec(rest) : null;
    if (!match) {
      out.push({ type: 'text', text: rest });
      break;
    }
    if (match.index > 0) out.push({ type: 'text', text: rest.slice(0, match.index) });
    const [, strongA, strongB, emA, emB] = match;
    const strong = strongA ?? strongB;
    if (strong !== undefined) {
      out.push({ type: 'strong', children: parseInline(strong, depth + 1) });
    } else {
      out.push({ type: 'em', children: parseInline(emA ?? emB ?? '', depth + 1) });
    }
    rest = rest.slice(match.index + match[0].length);
  }
  return out;
}

export function parseMarkdown(source: string): MdBlock[] {
  const lines = source.replace(/\r\n?/g, '\n').split('\n');
  const blocks: MdBlock[] = [];
  let paragraph: MdInline[][] = [];
  let list: Extract<MdBlock, { type: 'list' }> | null = null;

  const flushParagraph = () => {
    if (paragraph.length > 0) blocks.push({ type: 'paragraph', lines: paragraph });
    paragraph = [];
  };
  const flushList = () => {
    if (list) blocks.push(list);
    list = null;
  };

  for (const raw of lines) {
    const line = raw.replace(/\t/g, '    ');
    if (line.trim() === '') {
      flushParagraph();
      flushList();
      continue;
    }
    const heading = HEADING_RE.exec(line);
    if (heading) {
      flushParagraph();
      flushList();
      const level = Math.min(6, heading[1]?.length ?? 1) as 1 | 2 | 3 | 4 | 5 | 6;
      blocks.push({ type: 'heading', level, children: parseInline(heading[2] ?? '') });
      continue;
    }
    const bullet = BULLET_RE.exec(line);
    const ordered = bullet ? null : ORDERED_RE.exec(line);
    if (bullet || ordered) {
      flushParagraph();
      const isOrdered = ordered !== null;
      const itemText = (bullet ? bullet[1] : ordered?.[2]) ?? '';
      if (!list || list.ordered !== isOrdered) {
        flushList();
        list = {
          type: 'list',
          ordered: isOrdered,
          start: isOrdered ? Number(ordered[1] ?? 1) : 1,
          items: [],
        };
      }
      list.items.push(parseInline(itemText.trim()));
      continue;
    }
    if (list && /^\s{2,}\S/.test(line)) {
      // indented continuation of the previous list item
      const last = list.items[list.items.length - 1];
      last?.push({ type: 'text', text: ' ' }, ...parseInline(line.trim()));
      continue;
    }
    flushList();
    paragraph.push(parseInline(line.trim()));
  }
  flushParagraph();
  flushList();
  return blocks;
}
