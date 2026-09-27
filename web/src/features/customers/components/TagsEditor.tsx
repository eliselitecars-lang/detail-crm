import { X } from 'lucide-react';
import { useId, useState, type KeyboardEvent } from 'react';
import { Input } from '@/components/ui';
import { MAX_TAG_LENGTH, MAX_TAGS, normalizeTags } from '../model';

export interface TagsEditorProps {
  value: readonly string[];
  onChange: (tags: string[]) => void;
  /** Existing tags offered as suggestions. */
  suggestions?: readonly string[];
  id?: string;
  disabled?: boolean;
  'aria-describedby'?: string;
}

/** Chips + input: Enter or comma adds a tag, Backspace on empty removes the last. */
export function TagsEditor({
  value,
  onChange,
  suggestions = [],
  id,
  disabled = false,
  ...aria
}: TagsEditorProps) {
  const [text, setText] = useState('');
  const listId = useId();
  const full = value.length >= MAX_TAGS;

  const add = (raw: string) => {
    const parts = raw.split(',');
    const next = normalizeTags([...value, ...parts.map((p) => p.slice(0, MAX_TAG_LENGTH))]);
    onChange(next.slice(0, MAX_TAGS));
    setText('');
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter' || event.key === ',') {
      if (text.trim()) {
        event.preventDefault();
        add(text);
      } else if (event.key === 'Enter') {
        event.preventDefault();
      }
    } else if (event.key === 'Backspace' && text === '' && value.length > 0) {
      onChange(value.slice(0, -1));
    }
  };

  const available = suggestions.filter(
    (s) => !value.some((v) => v.toLowerCase() === s.toLowerCase()),
  );

  return (
    <div className="flex flex-col gap-2">
      {value.length > 0 && (
        <ul className="flex flex-wrap gap-1.5" aria-label="Tags">
          {value.map((tag) => (
            <li
              key={tag}
              className="bg-primary-soft text-primary-ink inline-flex max-w-full items-center gap-1 rounded-full py-0.5 pr-1 pl-2.5 text-xs font-medium"
            >
              <span className="truncate">{tag}</span>
              <button
                type="button"
                disabled={disabled}
                onClick={() => onChange(value.filter((t) => t !== tag))}
                className="hover:bg-primary/15 rounded-full p-0.5"
                aria-label={`Remove tag ${tag}`}
              >
                <X className="size-3" aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
      )}
      <Input
        id={id}
        aria-describedby={aria['aria-describedby']}
        value={text}
        disabled={disabled || full}
        maxLength={MAX_TAG_LENGTH}
        list={available.length > 0 ? listId : undefined}
        placeholder={full ? `Up to ${MAX_TAGS} tags` : 'Type a tag and press Enter'}
        onChange={(event) => {
          const next = event.target.value;
          if (next.includes(',')) add(next);
          else setText(next);
        }}
        onKeyDown={onKeyDown}
        onBlur={() => {
          if (text.trim()) add(text);
        }}
      />
      {available.length > 0 && (
        <datalist id={listId}>
          {available.slice(0, 100).map((tag) => (
            <option key={tag} value={tag} />
          ))}
        </datalist>
      )}
    </div>
  );
}
