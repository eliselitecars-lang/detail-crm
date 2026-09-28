import { KeyValueList, type KeyValueItem } from '@/components/ui';
import {
  formatCustomValue,
  isEmptyCustomValue,
  type CustomData,
  type CustomFieldDef,
} from '@/lib/customFields';

export interface CustomFieldValuesProps {
  /** Field definitions (archived ones included, so saved answers keep their label). */
  fields: readonly CustomFieldDef[];
  data: CustomData;
  layout?: 'rows' | 'grid';
  /** Also list fields without an answer (as "—"). */
  showEmpty?: boolean;
  /** Rendered when nothing is answered and `showEmpty` is off. */
  emptyText?: string;
  className?: string;
}

/**
 * Read-only custom field answers in field order. Answers whose field no
 * longer exists are listed last under their key (the server keeps them).
 */
export function CustomFieldValues({
  fields,
  data,
  layout = 'rows',
  showEmpty = false,
  emptyText = 'No answers yet.',
  className,
}: CustomFieldValuesProps) {
  const known = new Set(fields.map((f) => f.key));
  const items: KeyValueItem[] = [];
  for (const field of fields) {
    const value = data[field.key];
    if (value === undefined || isEmptyCustomValue(value)) {
      if (showEmpty && !field.archived_at)
        items.push({ key: field.key, label: field.label, value: null });
      continue;
    }
    items.push({ key: field.key, label: field.label, value: formatCustomValue(field, value) });
  }
  for (const [key, value] of Object.entries(data)) {
    if (known.has(key) || isEmptyCustomValue(value)) continue;
    const type =
      typeof value === 'boolean' ? 'checkbox' : Array.isArray(value) ? 'multiselect' : 'text';
    items.push({ key, label: key, value: formatCustomValue({ type }, value) });
  }
  if (items.length === 0) {
    return <p className="text-muted text-sm">{emptyText}</p>;
  }
  return <KeyValueList items={items} layout={layout} className={className} />;
}
