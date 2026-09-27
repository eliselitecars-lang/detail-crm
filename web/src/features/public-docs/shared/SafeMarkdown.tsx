import { Fragment, type ReactNode } from 'react';
import { parseMarkdown, type MdInline } from './markdown';

function renderInline(nodes: MdInline[]): ReactNode {
  return nodes.map((node, i) => {
    if (node.type === 'text') return <Fragment key={i}>{node.text}</Fragment>;
    if (node.type === 'strong') return <strong key={i}>{renderInline(node.children)}</strong>;
    return <em key={i}>{renderInline(node.children)}</em>;
  });
}

const HEADING_CLASSES = [
  'text-lg font-semibold',
  'text-base font-semibold',
  'text-sm font-semibold',
  'text-sm font-semibold',
  'text-sm font-medium',
  'text-sm font-medium',
] as const;

/**
 * Renders form text. Heading levels are shifted by `headingOffset` so a
 * document "# Title" becomes an <h2> under the page's own <h1>.
 */
export function SafeMarkdown({
  source,
  headingOffset = 1,
  className,
}: {
  source: string;
  headingOffset?: number;
  className?: string;
}) {
  const blocks = parseMarkdown(source);
  return (
    <div className={className ?? 'text-ink flex flex-col gap-3 text-sm leading-relaxed'}>
      {blocks.map((block, i) => {
        if (block.type === 'heading') {
          const level = Math.min(6, block.level + headingOffset);
          const Tag = `h${level}` as 'h2';
          return (
            <Tag key={i} className={`text-ink mt-2 ${HEADING_CLASSES[block.level - 1] ?? ''}`}>
              {renderInline(block.children)}
            </Tag>
          );
        }
        if (block.type === 'list') {
          const items = block.items.map((item, j) => <li key={j}>{renderInline(item)}</li>);
          return block.ordered ? (
            <ol key={i} start={block.start} className="list-decimal space-y-1 pl-6">
              {items}
            </ol>
          ) : (
            <ul key={i} className="list-disc space-y-1 pl-6">
              {items}
            </ul>
          );
        }
        return (
          <p key={i} className="break-words">
            {block.lines.map((line, j) => (
              <Fragment key={j}>
                {j > 0 && <br />}
                {renderInline(line)}
              </Fragment>
            ))}
          </p>
        );
      })}
    </div>
  );
}
