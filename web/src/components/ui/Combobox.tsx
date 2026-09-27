import { Check, ChevronsUpDown, Plus, X } from 'lucide-react';
import { useId, useRef, useState, type ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { controlClasses, useFormFieldControl } from './formFieldContext';
import { Spinner } from './Spinner';
import { useOutsideClick } from './overlay';

export interface ComboboxProps<T> {
  /** Selected option (controlled). */
  value: T | null;
  onChange: (value: T | null) => void;
  /** Current options for the query; fetch them in the parent (TanStack Query). */
  options: readonly T[];
  /** Fires (immediately) as the user types — debounce in the query key or here. */
  onQueryChange: (query: string) => void;
  getOptionValue: (option: T) => string;
  getOptionLabel: (option: T) => string;
  renderOption?: (option: T) => ReactNode;
  loading?: boolean;
  placeholder?: string;
  emptyText?: string;
  /** Offers "Create “query”" as the last option. */
  onCreate?: (query: string) => void;
  createLabel?: (query: string) => string;
  disabled?: boolean;
  clearable?: boolean;
  id?: string;
  'aria-label'?: string;
  'aria-describedby'?: string;
  'aria-invalid'?: boolean;
  required?: boolean;
  className?: string;
}

/**
 * Searchable async select (WAI-ARIA 1.2 combobox + listbox). The parent
 * owns the data: it receives `onQueryChange` and passes back `options` and
 * `loading`. Works inside <FormField> for label/error wiring.
 */
export function Combobox<T>({
  value,
  onChange,
  options,
  onQueryChange,
  getOptionValue,
  getOptionLabel,
  renderOption,
  loading = false,
  placeholder = 'Search…',
  emptyText = 'No matches',
  onCreate,
  createLabel = (q) => `Create “${q}”`,
  clearable = true,
  className,
  ...rest
}: ComboboxProps<T>) {
  const field = useFormFieldControl(rest);
  const listId = useId();
  const autoId = useId();
  const inputId = field.id ?? `cbx-${autoId}`;
  const wrapperRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(-1);

  const trimmed = query.trim();
  const showCreate = Boolean(onCreate) && trimmed.length > 0;
  const total = options.length + (showCreate ? 1 : 0);
  const activeId =
    activeIndex >= 0 && activeIndex < total ? `${listId}-opt-${activeIndex}` : undefined;

  useOutsideClick([wrapperRef], () => setOpen(false), open);

  const updateQuery = (next: string) => {
    setQuery(next);
    setActiveIndex(-1);
    onQueryChange(next);
    setOpen(true);
  };

  const select = (index: number) => {
    if (index < options.length) {
      const option = options[index];
      if (option !== undefined) onChange(option);
    } else if (showCreate) {
      onCreate?.(trimmed);
    }
    setOpen(false);
    setQuery('');
    setActiveIndex(-1);
  };

  const displayValue = open ? query : value !== null ? getOptionLabel(value) : '';

  return (
    <div ref={wrapperRef} className={cn('relative', className)}>
      <input
        ref={inputRef}
        id={inputId}
        type="text"
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={open ? activeId : undefined}
        aria-label={rest['aria-label']}
        aria-describedby={field['aria-describedby']}
        aria-invalid={field['aria-invalid']}
        aria-required={field.required}
        disabled={field.disabled}
        autoComplete="off"
        placeholder={value !== null && !open ? getOptionLabel(value) : placeholder}
        value={displayValue}
        onFocus={() => {
          if (!open) {
            setOpen(true);
            onQueryChange(query);
          }
        }}
        onChange={(event) => updateQuery(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown') {
            event.preventDefault();
            if (!open) setOpen(true);
            setActiveIndex((i) => (total === 0 ? -1 : (i + 1) % total));
          } else if (event.key === 'ArrowUp') {
            event.preventDefault();
            setActiveIndex((i) => (total === 0 ? -1 : (i - 1 + total) % total));
          } else if (event.key === 'Enter') {
            if (open && activeIndex >= 0) {
              event.preventDefault();
              select(activeIndex);
            }
          } else if (event.key === 'Escape') {
            if (open) {
              event.preventDefault();
              event.stopPropagation();
              setOpen(false);
              setQuery('');
            }
          } else if (event.key === 'Tab') {
            setOpen(false);
          }
        }}
        className={cn(controlClasses, 'h-9 pr-16')}
      />
      <div className="text-subtle absolute inset-y-0 right-0 flex items-center gap-0.5 pr-2">
        {loading && open && <Spinner className="size-4" />}
        {clearable && value !== null && !field.disabled && (
          <button
            type="button"
            aria-label="Clear selection"
            className="hover:text-ink rounded p-1"
            onClick={() => {
              onChange(null);
              inputRef.current?.focus();
            }}
          >
            <X className="size-3.5" aria-hidden="true" />
          </button>
        )}
        <ChevronsUpDown className="size-4" aria-hidden="true" />
      </div>
      {open && (
        <ul
          id={listId}
          role="listbox"
          aria-label={typeof rest['aria-label'] === 'string' ? rest['aria-label'] : 'Options'}
          className="rounded-card border-line bg-surface shadow-pop absolute z-40 mt-1 max-h-72 w-full overflow-y-auto border py-1"
        >
          {options.map((option, index) => {
            const selected = value !== null && getOptionValue(value) === getOptionValue(option);
            return (
              // Keyboard selection happens in the combobox input (aria-activedescendant).
              // eslint-disable-next-line jsx-a11y/click-events-have-key-events
              <li
                key={getOptionValue(option)}
                id={`${listId}-opt-${index}`}
                role="option"
                aria-selected={selected}
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => select(index)}
                onMouseMove={() => setActiveIndex(index)}
                className={cn(
                  'text-ink flex cursor-pointer items-center justify-between gap-2 px-3 py-2 text-sm',
                  index === activeIndex && 'bg-surface-2',
                )}
              >
                <span className="min-w-0 flex-1">
                  {renderOption ? renderOption(option) : getOptionLabel(option)}
                </span>
                {selected && <Check className="text-primary size-4" aria-hidden="true" />}
              </li>
            );
          })}
          {showCreate && (
            // eslint-disable-next-line jsx-a11y/click-events-have-key-events -- see above
            <li
              id={`${listId}-opt-${options.length}`}
              role="option"
              aria-selected={false}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => select(options.length)}
              onMouseMove={() => setActiveIndex(options.length)}
              className={cn(
                'border-line text-primary-ink flex cursor-pointer items-center gap-2 border-t px-3 py-2 text-sm font-medium',
                activeIndex === options.length && 'bg-surface-2',
              )}
            >
              <Plus className="size-4" aria-hidden="true" />
              {createLabel(trimmed)}
            </li>
          )}
          {options.length === 0 && !showCreate && (
            <li role="presentation" className="text-muted px-3 py-2 text-sm">
              {loading ? 'Searching…' : emptyText}
            </li>
          )}
        </ul>
      )}
    </div>
  );
}
