import { X } from 'lucide-react';
import { useId, useRef, type ReactNode, type RefObject } from 'react';
import { cn } from '@/lib/cn';
import { IconButton } from './IconButton';
import { Portal } from './Portal';
import { useEscapeKey, useFocusTrap, useScrollLock } from './overlay';

export interface DialogProps {
  open: boolean;
  onClose: () => void;
  title: ReactNode;
  description?: ReactNode;
  children?: ReactNode;
  /** Footer actions, right-aligned (stacked on small screens). */
  footer?: ReactNode;
  size?: 'sm' | 'md' | 'lg' | 'xl';
  /** Element to focus on open (defaults to the first focusable). */
  initialFocus?: RefObject<HTMLElement | null>;
  /** Prevent closing by Escape / backdrop (e.g. while saving). */
  dismissible?: boolean;
  /** role="alertdialog" for destructive confirmations. */
  role?: 'dialog' | 'alertdialog';
  className?: string;
}

const widths = { sm: 'max-w-sm', md: 'max-w-lg', lg: 'max-w-2xl', xl: 'max-w-4xl' } as const;

/** Accessible modal: focus trap, Escape, backdrop click, scroll lock, focus restore. */
export function Dialog({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  size = 'md',
  initialFocus,
  dismissible = true,
  role = 'dialog',
  className,
}: DialogProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const descId = useId();
  useScrollLock(open);
  useFocusTrap(panelRef, open, initialFocus);
  useEscapeKey(open && dismissible, onClose);

  if (!open) return null;

  return (
    <Portal>
      <div className="fixed inset-0 z-50 flex items-end justify-center p-0 sm:items-center sm:p-4">
        <div
          className="bg-overlay absolute inset-0"
          aria-hidden="true"
          onClick={() => dismissible && onClose()}
        />
        <div
          ref={panelRef}
          role={role}
          aria-modal="true"
          aria-labelledby={titleId}
          aria-describedby={description ? descId : undefined}
          tabIndex={-1}
          className={cn(
            'rounded-t-card border-line bg-surface shadow-pop sm:rounded-card relative flex max-h-[92dvh] w-full flex-col border outline-none',
            widths[size],
            className,
          )}
        >
          <div className="border-line flex items-start justify-between gap-3 border-b px-5 py-4">
            <div className="min-w-0">
              <h2 id={titleId} className="text-ink text-base font-semibold">
                {title}
              </h2>
              {description && (
                <p id={descId} className="text-muted mt-1 text-sm">
                  {description}
                </p>
              )}
            </div>
            {dismissible && <IconButton label="Close" icon={<X />} size="sm" onClick={onClose} />}
          </div>
          {children !== undefined && (
            <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">{children}</div>
          )}
          {footer && (
            <div className="border-line flex flex-col-reverse gap-2 border-t px-5 py-3 sm:flex-row sm:justify-end">
              {footer}
            </div>
          )}
        </div>
      </div>
    </Portal>
  );
}
