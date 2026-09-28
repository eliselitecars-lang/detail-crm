import { useId } from 'react';
import { Checkbox, DateInput, FormField, Input, Select, Textarea } from '@/components/ui';
import { cn } from '@/lib/cn';
import type { CustomDraftValue, CustomFieldDef, CustomFieldDraft } from '@/lib/customFields';

export interface CustomFieldInputsProps {
  /** Fields to render, in order. Archived fields render read-only when they hold a value. */
  fields: readonly CustomFieldDef[];
  /** Draft values (see `toDraft` / `fromDraft` in @/lib/customFields). */
  value: CustomFieldDraft;
  onChange: (next: CustomFieldDraft) => void;
  /** key → message (from `fromDraft(...).errors` or a server refusal). */
  errors?: Readonly<Record<string, string | undefined>>;
  /** Mark required fields (public booking questions / lead forms). */
  showRequired?: boolean;
  disabled?: boolean;
  /** Grid on wide screens (staff cards); one column otherwise. */
  columns?: 1 | 2;
  className?: string;
}

/**
 * Inputs for custom fields (booking questions, lead forms, customer / job
 * custom data). Controlled: the parent keeps the draft and converts it with
 * `fromDraft` before saving. Every control is labelled and wired to its
 * help / error text for screen readers.
 */
export function CustomFieldInputs({
  fields,
  value,
  onChange,
  errors = {},
  showRequired = false,
  disabled = false,
  columns = 1,
  className,
}: CustomFieldInputsProps) {
  const visible = fields.filter((f) => !f.archived_at || hasDraftValue(value[f.key]));
  if (visible.length === 0) return null;
  const set = (key: string, next: CustomDraftValue) => onChange({ ...value, [key]: next });
  return (
    <div className={cn('grid grid-cols-1 gap-4', columns === 2 && 'sm:grid-cols-2', className)}>
      {visible.map((field) => (
        <CustomFieldInput
          key={field.key}
          field={field}
          value={value[field.key]}
          error={errors[field.key]}
          required={showRequired && field.required === true}
          disabled={disabled || Boolean(field.archived_at)}
          wide={field.type === 'textarea' || field.type === 'multiselect'}
          onChange={(next) => set(field.key, next)}
        />
      ))}
    </div>
  );
}

function hasDraftValue(value: CustomDraftValue | undefined): boolean {
  if (value === undefined || value === false) return false;
  if (typeof value === 'string') return value.trim() !== '';
  return Array.isArray(value) ? value.length > 0 : true;
}

interface CustomFieldInputProps {
  field: CustomFieldDef;
  value: CustomDraftValue | undefined;
  error: string | undefined;
  required: boolean;
  disabled: boolean;
  wide: boolean;
  onChange: (next: CustomDraftValue) => void;
}

function CustomFieldInput({
  field,
  value,
  error,
  required,
  disabled,
  wide,
  onChange,
}: CustomFieldInputProps) {
  const groupId = useId();
  const help = field.archived_at
    ? 'This field is archived; its saved answer is kept as is.'
    : (field.help_text ?? undefined);
  const text = typeof value === 'string' ? value : '';
  const span = wide ? 'sm:col-span-full' : undefined;

  if (field.type === 'checkbox') {
    const errorId = `${groupId}-error`;
    return (
      <div className={cn('flex flex-col gap-1', span)}>
        <Checkbox
          label={
            <>
              {field.label}
              {required && (
                <span className="text-danger-ink ml-0.5" aria-hidden="true">
                  *
                </span>
              )}
            </>
          }
          description={help}
          checked={value === true}
          disabled={disabled}
          required={required}
          aria-invalid={error ? true : undefined}
          aria-errormessage={error ? errorId : undefined}
          onChange={(event) => onChange(event.target.checked)}
        />
        {error && (
          <p id={errorId} role="alert" className="text-danger-ink text-xs font-medium">
            {error}
          </p>
        )}
      </div>
    );
  }

  if (field.type === 'multiselect') {
    const selected = Array.isArray(value) ? value : [];
    const helpId = `${groupId}-help`;
    const errorId = `${groupId}-error`;
    return (
      <fieldset
        className={cn('flex min-w-0 flex-col gap-1.5', span)}
        aria-describedby={error ? errorId : help ? helpId : undefined}
        aria-invalid={error ? true : undefined}
        disabled={disabled}
      >
        <legend className="text-ink mb-1.5 text-sm font-medium">
          {field.label}
          {required && (
            <span className="text-danger-ink ml-0.5" aria-hidden="true">
              *
            </span>
          )}
          {required && <span className="sr-only"> (required)</span>}
        </legend>
        <div className="flex flex-wrap gap-x-5 gap-y-2">
          {field.options.map((option) => (
            <Checkbox
              key={option}
              label={option}
              checked={selected.includes(option)}
              onChange={(event) =>
                onChange(
                  event.target.checked
                    ? field.options.filter((o) => o === option || selected.includes(o))
                    : selected.filter((o) => o !== option),
                )
              }
            />
          ))}
        </div>
        {error ? (
          <p id={errorId} role="alert" className="text-danger-ink text-xs font-medium">
            {error}
          </p>
        ) : help ? (
          <p id={helpId} className="text-muted text-xs">
            {help}
          </p>
        ) : null}
      </fieldset>
    );
  }

  return (
    <FormField
      label={field.label}
      help={help}
      error={error}
      required={required}
      disabled={disabled}
      className={span}
    >
      {field.type === 'textarea' ? (
        <Textarea
          rows={3}
          maxLength={10000}
          value={text}
          onChange={(event) => onChange(event.target.value)}
        />
      ) : field.type === 'select' ? (
        <Select
          value={text}
          placeholder={required ? 'Choose…' : 'No answer'}
          options={[
            ...field.options.map((o) => ({ value: o, label: o })),
            // an answer saved before the options changed stays visible
            ...(text !== '' && !field.options.includes(text) ? [{ value: text, label: text }] : []),
          ]}
          onChange={(event) => onChange(event.target.value)}
        />
      ) : field.type === 'date' ? (
        <DateInput value={text} onChange={(event) => onChange(event.target.value)} />
      ) : field.type === 'number' ? (
        <Input
          inputMode="decimal"
          autoComplete="off"
          value={text}
          onChange={(event) => onChange(event.target.value)}
        />
      ) : (
        <Input
          autoComplete="off"
          maxLength={2000}
          value={text}
          onChange={(event) => onChange(event.target.value)}
        />
      )}
    </FormField>
  );
}
