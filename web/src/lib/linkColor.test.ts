import { describe, expect, it } from 'vitest';

/**
 * Link text uses `text-primary-ink` (#1553b8 light / #7fb0ff dark, ≥ 4.5:1 on
 * every surface — e2e/contrast.spec.ts). `text-primary` is the button-fill
 * blue (#1f6feb in both themes): fine for icons, but 3.7:1 as small text on
 * the dark surface, so it must never colour a link or underlined text.
 */
const sources = import.meta.glob<string>('/src/**/*.tsx', {
  query: '?raw',
  import: 'default',
  eager: true,
});

const FILL_TOKEN = /(^|\s)text-primary(?=\s|$)/;

function classNames(source: string): { value: string; tag: string }[] {
  const found: { value: string; tag: string }[] = [];
  const re = /<(\w+)\b[^>]*?className="([^"]*)"/g;
  for (const match of source.matchAll(re)) found.push({ tag: match[1]!, value: match[2]! });
  return found;
}

describe('link colour token', () => {
  it('scans the app’s components', () => {
    expect(Object.keys(sources).length).toBeGreaterThan(100);
  });

  it('never colours a link or underlined text with the fill token text-primary', () => {
    const offenders: string[] = [];
    for (const [file, source] of Object.entries(sources)) {
      if (file.endsWith('.test.tsx')) continue;
      for (const { tag, value } of classNames(source)) {
        if (!FILL_TOKEN.test(value)) continue;
        if (tag === 'Link' || tag === 'a' || /(^|\s)(hover:)?underline(\s|$)/.test(value)) {
          offenders.push(`${file}: <${tag} className="${value}">`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });
});
