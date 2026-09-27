import { useId, useRef, type KeyboardEvent, type ReactNode } from 'react';
import { cn } from '@/lib/cn';

export interface TabItem<V extends string> {
  value: V;
  label: ReactNode;
  /** Small count shown after the label. */
  count?: number;
  disabled?: boolean;
  /** Panel content; omit to render only the tab list (e.g. filters). */
  content?: ReactNode;
}

export interface TabsProps<V extends string> {
  /** Accessible name of the tab list. */
  label: string;
  items: readonly TabItem<V>[];
  value: V;
  onChange: (value: V) => void;
  className?: string;
  listClassName?: string;
}

/** WAI-ARIA tabs (automatic activation, roving tabindex, arrows/Home/End). */
export function Tabs<V extends string>({
  label,
  items,
  value,
  onChange,
  className,
  listClassName,
}: TabsProps<V>) {
  const baseId = useId();
  const refs = useRef<(HTMLButtonElement | null)[]>([]);
  const enabled = items.map((item, i) => (item.disabled ? -1 : i)).filter((i) => i >= 0);
  const active = items.find((item) => item.value === value);

  const onKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    const current = items.findIndex((item) => item.value === value);
    const pos = enabled.indexOf(current);
    let next: number | undefined;
    if (event.key === 'ArrowRight') next = enabled[(pos + 1) % enabled.length];
    else if (event.key === 'ArrowLeft') next = enabled[(pos - 1 + enabled.length) % enabled.length];
    else if (event.key === 'Home') next = enabled[0];
    else if (event.key === 'End') next = enabled[enabled.length - 1];
    if (next === undefined) return;
    event.preventDefault();
    const item = items[next];
    if (!item) return;
    onChange(item.value);
    refs.current[next]?.focus();
  };

  return (
    <div className={className}>
      <div
        role="tablist"
        aria-label={label}
        className={cn('border-line -mb-px flex gap-1 overflow-x-auto border-b', listClassName)}
      >
        {items.map((item, index) => {
          const selected = item.value === value;
          return (
            <button
              key={item.value}
              ref={(el) => {
                refs.current[index] = el;
              }}
              id={`${baseId}-tab-${item.value}`}
              type="button"
              role="tab"
              aria-selected={selected}
              aria-controls={
                item.content !== undefined ? `${baseId}-panel-${item.value}` : undefined
              }
              tabIndex={selected ? 0 : -1}
              disabled={item.disabled}
              onClick={() => onChange(item.value)}
              onKeyDown={onKeyDown}
              className={cn(
                'inline-flex shrink-0 items-center gap-1.5 border-b-2 px-3 py-2 text-sm font-medium transition-colors focus-visible:outline-offset-[-2px] disabled:opacity-55',
                selected
                  ? 'border-primary text-primary-ink'
                  : 'text-muted hover:text-ink border-transparent',
              )}
            >
              {item.label}
              {item.count !== undefined && (
                <span
                  className={cn(
                    'tabular rounded-full px-1.5 text-xs',
                    selected ? 'bg-primary-soft text-primary-ink' : 'bg-surface-2 text-muted',
                  )}
                >
                  {item.count}
                </span>
              )}
            </button>
          );
        })}
      </div>
      {active?.content !== undefined && (
        <div
          role="tabpanel"
          id={`${baseId}-panel-${active.value}`}
          aria-labelledby={`${baseId}-tab-${active.value}`}
          tabIndex={0}
          className="pt-4 focus-visible:outline-offset-4"
        >
          {active.content}
        </div>
      )}
    </div>
  );
}
