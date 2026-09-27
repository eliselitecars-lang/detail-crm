import { X } from 'lucide-react';
import { useId, useRef, type ReactNode, type RefObject } from 'react';
import { cn } from '@/lib/cn';
import { IconButton } from './IconButton';
import { Portal } from './Portal';
import { useEscapeKey, useFocusTrap, useScrollLock } from './overlay';

export interface DrawerProps {
  open: boolean;
  onClose: () => void;
  /** Accessible title; shown in the header unless `hideHeader`. */
  title: ReactNode;
  description?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  side?: 'left' | 'right';
  /** Panel width class, e.g. "max-w-md". */
  widthClassName?: string;
  hideHeader?: boolean;
  initialFocus?: RefObject<HTMLElement | null>;
  className?: string;
}

/** Side sheet (modal): mobile nav, quick-edit panels, filters. */
export function Drawer({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  side = 'right',
  widthClassName = 'max-w-md',
  hideHeader = false,
  initialFocus,
  className,
}: DrawerProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useScrollLock(open);
  useFocusTrap(panelRef, open, initialFocus);
  useEscapeKey(open, onClose);
  if (!open) return null;

  return (
    <Portal>
      <div className="fixed inset-0 z-50 flex">
        <div className="bg-overlay absolute inset-0" aria-hidden="true" onClick={onClose} />
        <div
          ref={panelRef}
          role="dialog"
          aria-modal="true"
          aria-labelledby={titleId}
          tabIndex={-1}
          className={cn(
            'border-line bg-surface shadow-pop relative flex h-full w-[88vw] flex-col outline-none',
            side === 'right' ? 'ml-auto border-l' : 'mr-auto border-r',
            widthClassName,
            className,
          )}
        >
          <div
            className={cn(
              'border-line flex items-start justify-between gap-3 border-b px-5 py-4',
              hideHeader && 'sr-only',
            )}
          >
            <div className="min-w-0">
              <h2 id={titleId} className="text-ink text-base font-semibold">
                {title}
              </h2>
              {description && <p className="text-muted mt-1 text-sm">{description}</p>}
            </div>
            <IconButton label="Close" icon={<X />} size="sm" onClick={onClose} />
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto">{children}</div>
          {footer && (
            <div className="border-line flex justify-end gap-2 border-t px-5 py-3">{footer}</div>
          )}
        </div>
      </div>
    </Portal>
  );
}
