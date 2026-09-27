import { useState, type ComponentProps } from 'react';
import { centsToInputValue, parseMoneyInput, type Cents } from '@/lib/money';
import { Input } from './Input';

export interface MoneyInputProps extends Omit<
  ComponentProps<'input'>,
  'value' | 'onChange' | 'type' | 'defaultValue'
> {
  /** Integer cents (or null for empty). */
  value: Cents | null | undefined;
  onChange: (cents: Cents | null) => void;
  allowNegative?: boolean;
  maxCents?: Cents;
  inputSize?: 'sm' | 'md' | 'lg';
}

const PARTIAL_RE = /^\(?-?\$?[\d,]*\.?\d{0,2}\)?$/;

/**
 * Dollar input that reports integer cents. Typing is restricted to at most
 * two decimals; the text is normalised ("12.5" → "12.50") on blur.
 * Use with react-hook-form via <Controller>.
 */
export function MoneyInput({
  value,
  onChange,
  onBlur,
  allowNegative = false,
  maxCents,
  ...rest
}: MoneyInputProps) {
  const options = { allowNegative, ...(maxCents !== undefined ? { maxCents } : {}) };
  const [text, setText] = useState(() => centsToInputValue(value));
  const [lastValue, setLastValue] = useState(value);

  // Adopt external value changes (form reset, server data) without clobbering
  // what the user is typing when it already represents the same amount.
  if (value !== lastValue) {
    setLastValue(value);
    if (parseMoneyInput(text, options) !== (value ?? null)) setText(centsToInputValue(value));
  }

  return (
    <Input
      {...rest}
      type="text"
      inputMode="decimal"
      autoComplete="off"
      leading="$"
      value={text}
      onChange={(event) => {
        const next = event.target.value.replace(/^\$/, '');
        if (next !== '' && !PARTIAL_RE.test(next)) return;
        if (!allowNegative && next.includes('-')) return;
        setText(next);
        const cents = parseMoneyInput(next, options);
        setLastValue(cents);
        onChange(cents);
      }}
      onBlur={(event) => {
        const cents = parseMoneyInput(text, options);
        if (cents !== null) setText(centsToInputValue(cents));
        onBlur?.(event);
      }}
      className="tabular"
    />
  );
}
