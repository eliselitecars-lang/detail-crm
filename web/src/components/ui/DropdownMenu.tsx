import { useId, useRef, useState, type KeyboardEvent, type ReactNode, type RefObject } from 'react';
import { cn } from '@/lib/cn';
import { useEscapeKey, useOutsideClick } from './overlay';

export interface DropdownMenuItem {
  key: string;
  label: ReactNode;
  icon?: ReactNode;
  onSelect: () => void;
  disabled?: boolean;
  tone?: 'default' | 'danger';
}

export interface DropdownMenuSeparator {
  key: string;
  separator: true;
}

export type DropdownMenuEntry = DropdownMenuItem | DropdownMenuSeparator;

export interface DropdownMenuProps {
  /** Renders the trigger; spread `props` onto a <button>. */
  trigger: (props: {
    ref: RefObject<HTMLButtonElement | null>;
    id: string;
    'aria-haspopup': 'menu';
    'aria-expanded': boolean;
    'aria-controls': string;
    onClick: () => void;
    onKeyDown: (event: KeyboardEvent<HTMLButtonElement>) => void;
  }) => ReactNode;
  items: readonly DropdownMenuEntry[];
  align?: 'start' | 'end';
  /** Optional header content inside the menu (e.g. signed-in email). */
  header?: ReactNode;
  className?: string;
  menuClassName?: string;
}

function isItem(entry: DropdownMenuEntry): entry is DropdownMenuItem {
  return !('separator' in entry);
}

/**
 * WAI-ARIA menu button: Enter/Space/ArrowDown open and focus the first item,
 * ArrowUp/Down/Home/End move, Escape closes and returns focus, Tab closes.
 */
export function DropdownMenu({
  trigger,
  items,
  align = 'end',
  header,
  className,
  menuClassName,
}: DropdownMenuProps) {
  const [open, setOpen] = useState(false);
  const menuId = useId();
  const triggerId = useId();
  const wrapperRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const itemRefs = useRef<(HTMLButtonElement | null)[]>([]);
  const enabledIndexes = items
    .map((entry, index) => (isItem(entry) && !entry.disabled ? index : -1))
    .filter((index) => index >= 0);

  const close = (restoreFocus: boolean) => {
    setOpen(false);
    if (restoreFocus) triggerRef.current?.focus();
  };
  useOutsideClick([wrapperRef], () => setOpen(false), open);
  useEscapeKey(open, () => close(true));

  const focusIndex = (index: number | undefined) => {
    if (index === undefined) return;
    itemRefs.current[index]?.focus();
  };

  const openAndFocus = (which: 'first' | 'last') => {
    setOpen(true);
    requestAnimationFrame(() =>
      focusIndex(which === 'first' ? enabledIndexes[0] : enabledIndexes[enabledIndexes.length - 1]),
    );
  };

  const onMenuKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const current = itemRefs.current.findIndex((el) => el === document.activeElement);
    const pos = enabledIndexes.indexOf(current);
    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        focusIndex(enabledIndexes[(pos + 1) % enabledIndexes.length]);
        break;
      case 'ArrowUp':
        event.preventDefault();
        focusIndex(enabledIndexes[(pos - 1 + enabledIndexes.length) % enabledIndexes.length]);
        break;
      case 'Home':
        event.preventDefault();
        focusIndex(enabledIndexes[0]);
        break;
      case 'End':
        event.preventDefault();
        focusIndex(enabledIndexes[enabledIndexes.length - 1]);
        break;
      case 'Tab':
        setOpen(false);
        break;
      default:
        break;
    }
  };

  return (
    <div ref={wrapperRef} className={cn('relative inline-flex', className)}>
      {trigger({
        ref: triggerRef,
        id: triggerId,
        'aria-haspopup': 'menu',
        'aria-expanded': open,
        'aria-controls': menuId,
        onClick: () => (open ? setOpen(false) : openAndFocus('first')),
        onKeyDown: (event) => {
          if (event.key === 'ArrowDown') {
            event.preventDefault();
            openAndFocus('first');
          } else if (event.key === 'ArrowUp') {
            event.preventDefault();
            openAndFocus('last');
          }
        },
      })}
      {open && (
        <div
          id={menuId}
          role="menu"
          aria-labelledby={triggerId}
          tabIndex={-1}
          onKeyDown={onMenuKeyDown}
          className={cn(
            'rounded-card border-line bg-surface shadow-pop absolute top-full z-40 mt-1.5 min-w-52 overflow-hidden border py-1',
            align === 'end' ? 'right-0' : 'left-0',
            menuClassName,
          )}
        >
          {header && <div className="border-line border-b px-3 py-2">{header}</div>}
          {items.map((entry, index) =>
            isItem(entry) ? (
              <button
                key={entry.key}
                ref={(el) => {
                  itemRefs.current[index] = el;
                }}
                type="button"
                role="menuitem"
                tabIndex={-1}
                disabled={entry.disabled}
                onClick={() => {
                  close(true);
                  entry.onSelect();
                }}
                className={cn(
                  'hover:bg-surface-2 focus:bg-surface-2 flex w-full items-center gap-2.5 px-3 py-2 text-left text-sm outline-none disabled:cursor-not-allowed disabled:opacity-55 [&_svg]:size-4',
                  entry.tone === 'danger' ? 'text-danger-ink' : 'text-ink',
                )}
              >
                {entry.icon && (
                  <span aria-hidden="true" className="text-muted">
                    {entry.icon}
                  </span>
                )}
                {entry.label}
              </button>
            ) : (
              <div key={entry.key} role="separator" className="border-line my-1 border-t" />
            ),
          )}
        </div>
      )}
    </div>
  );
}
