import { Search, X } from 'lucide-react';
import { useEffect, useRef, useState, type ComponentProps } from 'react';
import { Input } from './Input';
import { IconButton } from './IconButton';

export interface SearchInputProps extends Omit<
  ComponentProps<'input'>,
  'value' | 'onChange' | 'type' | 'defaultValue'
> {
  value: string;
  /** Called after `debounceMs` of inactivity (immediately on clear). */
  onChange: (value: string) => void;
  debounceMs?: number;
  /** Accessible label when there is no visible one. */
  label?: string;
  inputSize?: 'sm' | 'md' | 'lg';
}

/** Debounced search box with a clear button. */
export function SearchInput({
  value,
  onChange,
  debounceMs = 250,
  label = 'Search',
  placeholder = 'Search…',
  ...rest
}: SearchInputProps) {
  const [text, setText] = useState(value);
  const [lastValue, setLastValue] = useState(value);
  if (value !== lastValue) {
    setLastValue(value);
    setText(value);
  }
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);

  const emit = (next: string, immediate: boolean) => {
    clearTimeout(timer.current);
    if (immediate || debounceMs <= 0) {
      setLastValue(next);
      onChange(next);
      return;
    }
    timer.current = setTimeout(() => {
      setLastValue(next);
      onChange(next);
    }, debounceMs);
  };

  return (
    <Input
      {...rest}
      type="search"
      role="searchbox"
      aria-label={rest['aria-label'] ?? label}
      placeholder={placeholder}
      leading={<Search />}
      trailing={
        text ? (
          <IconButton
            size="sm"
            label="Clear search"
            icon={<X />}
            onClick={() => {
              setText('');
              emit('', true);
            }}
          />
        ) : undefined
      }
      value={text}
      onChange={(event) => {
        setText(event.target.value);
        emit(event.target.value, false);
      }}
      onKeyDown={(event) => {
        if (event.key === 'Enter') emit(text, true);
        rest.onKeyDown?.(event);
      }}
    />
  );
}
