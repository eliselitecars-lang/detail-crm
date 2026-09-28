import { useState } from 'react';
import { CopyField, Tabs } from '@/components/ui';
import { embedIframeSnippet, embedScriptSnippet, type EmbedTarget } from '../embed';

/** "Embed on your website" snippets (auto-height script or a plain iframe). */
export function EmbedSnippets({ target, title }: { target: EmbedTarget; title: string }) {
  const [tab, setTab] = useState<'script' | 'iframe'>('script');
  return (
    <Tabs
      label="Embed code"
      value={tab}
      onChange={setTab}
      items={[
        {
          value: 'script',
          label: 'Script (recommended)',
          content: (
            <div className="flex flex-col gap-2 pt-3">
              <p className="text-muted text-xs">
                Paste where the form should appear. It resizes itself to fit.
              </p>
              <CopyField
                multiline
                value={embedScriptSnippet(target)}
                label="Embed script code"
                copiedMessage="Embed code copied"
              />
            </div>
          ),
        },
        {
          value: 'iframe',
          label: 'Plain iframe',
          content: (
            <div className="flex flex-col gap-2 pt-3">
              <p className="text-muted text-xs">
                For site builders that don’t allow scripts. It has a fixed height.
              </p>
              <CopyField
                multiline
                value={embedIframeSnippet(target, title)}
                label="Embed iframe code"
                copiedMessage="Embed code copied"
              />
            </div>
          ),
        },
      ]}
    />
  );
}
