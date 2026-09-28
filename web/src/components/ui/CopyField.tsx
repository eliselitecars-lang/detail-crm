import { Check, Copy } from 'lucide-react';
import { useEffect, useState, type ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { Button } from './Button';
import { useToast } from './toastContext';

export interface CopyFieldProps {
  /** The text shown and copied (a link, a secret, a code snippet). */
  value: string;
  /** Accessible name of the value ("Booking link"). */
  label: string;
  /** Toast after copying ("Link copied"). */
  copiedMessage?: string;
  /** Multi-line monospace block (embed snippets) instead of a single line. */
  multiline?: boolean;
  /** Extra actions next to Copy (e.g. an Open link). */
  actions?: ReactNode;
  className?: string;
}

/** A read-only value with a Copy button (clipboard API, with a manual fallback hint). */
export function CopyField({
  value,
  label,
  copiedMessage = 'Copied',
  multiline = false,
  actions,
  className,
}: CopyFieldProps) {
  const toast = useToast();
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 2000);
    return () => clearTimeout(timer);
  }, [copied]);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      toast.success(copiedMessage);
    } catch {
      toast.error('Couldn’t copy', 'Select the text and copy it manually.');
    }
  };

  return (
    <div
      className={cn(
        'flex min-w-0 flex-col gap-2',
        !multiline && 'sm:flex-row sm:items-center',
        className,
      )}
    >
      <output
        aria-label={label}
        className={cn(
          'border-line bg-surface-2 rounded-control text-ink min-w-0 border px-3 py-2 font-mono text-sm select-all',
          multiline ? 'block overflow-x-auto break-all whitespace-pre-wrap' : 'flex-1 truncate',
        )}
      >
        {value}
      </output>
      <div className="flex shrink-0 flex-wrap gap-2">
        <Button
          variant="secondary"
          leadingIcon={
            copied ? (
              <Check className="size-4" aria-hidden="true" />
            ) : (
              <Copy className="size-4" aria-hidden="true" />
            )
          }
          onClick={() => void copy()}
        >
          {copied ? 'Copied' : 'Copy'}
          <span className="sr-only"> {label.toLowerCase()}</span>
        </Button>
        {actions}
      </div>
    </div>
  );
}
