import type { ComponentProps } from 'react';
import { Phone } from 'lucide-react';
import { formatPhone, formatPhoneAsYouType } from '@/lib/phone';
import { Input } from './Input';

export interface PhoneInputProps extends Omit<
  ComponentProps<'input'>,
  'value' | 'onChange' | 'type' | 'defaultValue'
> {
  /** Raw text as typed/displayed. Validate + normalise with `zPhone` (lib/validation). */
  value: string | null | undefined;
  onChange: (value: string) => void;
}

/** US-formatting phone input ("(205) 555-0123"); "+" input is left as typed. */
export function PhoneInput({ value, onChange, ...rest }: PhoneInputProps) {
  const display = value ? (value.startsWith('+1') ? formatPhone(value) : value) : '';
  return (
    <Input
      {...rest}
      type="tel"
      inputMode="tel"
      autoComplete={rest.autoComplete ?? 'tel'}
      leading={<Phone />}
      value={display}
      onChange={(event) => onChange(formatPhoneAsYouType(event.target.value))}
    />
  );
}
