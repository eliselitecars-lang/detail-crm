import { Plus, Users, X } from 'lucide-react';
import { useId, useState, type KeyboardEvent } from 'react';
import { Badge, Button, DateInput, FormField, IconButton, Input, Select } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { useAudiencePreview, useCustomerTags } from '../api';
import {
  audienceFromForm,
  audienceRangeError,
  audienceToJson,
  describeAudience,
  MAX_TAGS,
  normalizeTags,
  type AudienceForm,
  type CampaignChannel,
  type Lifecycle,
} from '../model';

export interface AudienceBuilderProps {
  value: AudienceForm;
  onChange: (value: AudienceForm) => void;
  channel: CampaignChannel;
  disabled?: boolean;
}

/** Tags (any of), lifecycle and last-visit filters + a live recipient estimate. */
export function AudienceBuilder({
  value,
  onChange,
  channel,
  disabled = false,
}: AudienceBuilderProps) {
  const [tagText, setTagText] = useState('');
  const listId = useId();
  const tags = useCustomerTags();
  const audience = audienceFromForm(value);
  const rangeError = audienceRangeError(value);
  const preview = useAudiencePreview(channel, audienceToJson(audience), !rangeError);

  const addTag = () => {
    const next = normalizeTags([...value.tags, ...tagText.split(',')]);
    onChange({ ...value, tags: next });
    setTagText('');
  };
  const onTagKey = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter' || event.key === ',') {
      event.preventDefault();
      if (tagText.trim()) addTag();
    }
  };

  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 sm:grid-cols-2">
        <FormField
          label="Tags (any of)"
          help="Leave empty to include every tag. Press Enter to add."
          className="sm:col-span-2"
        >
          <div className="flex gap-2">
            <Input
              value={tagText}
              list={listId}
              disabled={disabled || value.tags.length >= MAX_TAGS}
              placeholder="e.g. vip"
              onChange={(e) => setTagText(e.target.value)}
              onKeyDown={onTagKey}
            />
            <Button
              type="button"
              variant="secondary"
              leadingIcon={<Plus />}
              disabled={disabled || tagText.trim() === ''}
              onClick={addTag}
            >
              Add
            </Button>
          </div>
        </FormField>
        <datalist id={listId}>
          {(tags.data ?? [])
            .filter((t) => !value.tags.some((v) => v.toLowerCase() === t.toLowerCase()))
            .map((t) => (
              <option key={t} value={t} />
            ))}
        </datalist>
        {value.tags.length > 0 && (
          <ul aria-label="Selected tags" className="flex flex-wrap gap-2 sm:col-span-2">
            {value.tags.map((tag) => (
              <li
                key={tag}
                className="bg-surface-2 text-ink border-line inline-flex items-center gap-1 rounded-full border py-0.5 pr-1 pl-2.5 text-sm"
              >
                {tag}
                <IconButton
                  size="sm"
                  label={`Remove tag ${tag}`}
                  icon={<X />}
                  disabled={disabled}
                  onClick={() => onChange({ ...value, tags: value.tags.filter((t) => t !== tag) })}
                />
              </li>
            ))}
          </ul>
        )}
        <FormField label="Lifecycle">
          <Select
            value={value.lifecycle}
            disabled={disabled}
            onChange={(e) => {
              const v = e.target.value;
              const lifecycle: Lifecycle | '' = v === 'lead' || v === 'customer' ? v : '';
              onChange({ ...value, lifecycle });
            }}
            options={[
              { value: '', label: 'Leads and customers' },
              { value: 'customer', label: 'Customers only' },
              { value: 'lead', label: 'Leads only' },
            ]}
          />
        </FormField>
        <div className="hidden sm:block" />
        <FormField
          label="Last visit on or after"
          help="Date in your shop’s time zone."
          error={rangeError ?? undefined}
        >
          <DateInput
            value={value.lastVisitAfter}
            disabled={disabled}
            onChange={(e) => onChange({ ...value, lastVisitAfter: e.target.value })}
          />
        </FormField>
        <FormField label="Last visit before" help="Customers with no completed job never match.">
          <DateInput
            value={value.lastVisitBefore}
            disabled={disabled}
            onChange={(e) => onChange({ ...value, lastVisitBefore: e.target.value })}
          />
        </FormField>
      </div>

      <div
        className="bg-surface-2 rounded-control flex items-start gap-3 p-3"
        aria-live="polite"
        aria-busy={preview.isFetching}
      >
        <Users className="text-muted mt-0.5 size-5 shrink-0" aria-hidden="true" />
        <div className="min-w-0 text-sm">
          <p className="text-ink font-medium">
            Estimated recipients:{' '}
            {rangeError ? (
              <Badge tone="warning">0</Badge>
            ) : preview.isPending ? (
              <span className="text-muted">calculating…</span>
            ) : preview.error ? (
              <span className="text-danger-ink">{errorMessage(preview.error)}</span>
            ) : (
              <Badge tone={preview.data === 0 ? 'warning' : 'info'}>
                {preview.data?.toLocaleString()}
              </Badge>
            )}
          </p>
          <p className="text-muted mt-1">{describeAudience(audience, channel)}.</p>
          <p className="text-muted mt-1 text-xs">
            An estimate until launch: the final list is built when you launch, from customers who
            are opted in and haven’t opted out at that moment (one message per address).
          </p>
        </div>
      </div>
    </div>
  );
}
