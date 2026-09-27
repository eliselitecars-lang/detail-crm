import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { parseInline, parseMarkdown } from './markdown';
import { SafeMarkdown } from './SafeMarkdown';

describe('parseInline', () => {
  it('reads bold and italic, nested', () => {
    expect(parseInline('a **bold _and italic_** c')).toEqual([
      { type: 'text', text: 'a ' },
      {
        type: 'strong',
        children: [
          { type: 'text', text: 'bold ' },
          { type: 'em', children: [{ type: 'text', text: 'and italic' }] },
        ],
      },
      { type: 'text', text: ' c' },
    ]);
  });

  it('leaves snake_case words and lone asterisks alone', () => {
    expect(parseInline('file_name_here costs 5 * 3')).toEqual([
      { type: 'text', text: 'file_name_here costs 5 * 3' },
    ]);
  });
});

describe('parseMarkdown', () => {
  it('splits headings, paragraphs and lists', () => {
    const blocks = parseMarkdown(
      '# Waiver\n\nFirst line\nsecond line\n\n- one\n- two\n\n3. three\n4. four',
    );
    expect(blocks.map((b) => b.type)).toEqual(['heading', 'paragraph', 'list', 'list']);
    expect(blocks[1]).toMatchObject({
      type: 'paragraph',
      lines: [[{ text: 'First line' }], [{ text: 'second line' }]],
    });
    expect(blocks[3]).toMatchObject({ type: 'list', ordered: true, start: 3 });
  });
});

describe('SafeMarkdown', () => {
  it('never renders HTML from the source', () => {
    const { container } = render(
      <SafeMarkdown
        source={'## Terms\n\n<script>alert(1)</script> <img src=x onerror=alert(1)> **ok**'}
      />,
    );
    expect(container.querySelector('script')).toBeNull();
    expect(container.querySelector('img')).toBeNull();
    expect(screen.getByText(/<script>alert\(1\)<\/script>/)).toBeInTheDocument();
    expect(screen.getByRole('heading', { level: 3, name: 'Terms' })).toBeInTheDocument();
    expect(container.querySelector('strong')).toHaveTextContent('ok');
  });

  it('renders lists as lists', () => {
    render(<SafeMarkdown source={'- Keep windows closed\n- Remove valuables'} />);
    expect(screen.getAllByRole('listitem')).toHaveLength(2);
  });
});
