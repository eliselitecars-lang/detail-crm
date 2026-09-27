import { cloneElement, useId, useState, type ReactElement, type HTMLAttributes } from 'react';
import { cn } from '@/lib/cn';

export interface TooltipProps {
  content: string;
  /** A single focusable element (button, link…). */
  children: ReactElement<HTMLAttributes<HTMLElement>>;
  side?: 'top' | 'bottom';
  className?: string;
}

/**
 * Hover/focus tooltip wired with aria-describedby. Supplemental only — never
 * put essential information (or the only label of an icon button) here.
 */
export function Tooltip({ content, children, side = 'top', className }: TooltipProps) {
  const [open, setOpen] = useState(false);
  const id = useId();
  const child = children;
  const trigger = cloneElement(child, {
    'aria-describedby': cn(child.props['aria-describedby'], open && id) || undefined,
    onMouseEnter: (event) => {
      setOpen(true);
      child.props.onMouseEnter?.(event);
    },
    onMouseLeave: (event) => {
      setOpen(false);
      child.props.onMouseLeave?.(event);
    },
    onFocus: (event) => {
      setOpen(true);
      child.props.onFocus?.(event);
    },
    onBlur: (event) => {
      setOpen(false);
      child.props.onBlur?.(event);
    },
    onKeyDown: (event) => {
      if (event.key === 'Escape') setOpen(false);
      child.props.onKeyDown?.(event);
    },
  });
  return (
    <span className="relative inline-flex">
      {trigger}
      {open && (
        <span
          id={id}
          role="tooltip"
          className={cn(
            'rounded-control bg-ink text-canvas shadow-pop pointer-events-none absolute left-1/2 z-50 w-max max-w-64 -translate-x-1/2 px-2 py-1 text-xs font-medium',
            side === 'top' ? 'bottom-full mb-1.5' : 'top-full mt-1.5',
            className,
          )}
        >
          {content}
        </span>
      )}
    </span>
  );
}
