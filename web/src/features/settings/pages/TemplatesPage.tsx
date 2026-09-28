import { Clock, Pencil, Eye } from 'lucide-react';
import { useMemo } from 'react';
import { useSearchParams } from 'react-router';
import { Badge, Button, SectionCard, Switch, useToast } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { LapsedAutomationsNotice } from '@/features/billing/components/LapsedNotice';
import { formatPhone } from '@/lib/phone';
import {
  useMessageTemplates,
  useShopSettings,
  useUpdateTemplate,
  type MessageTemplate,
  type TemplateKey,
} from '../api';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { TemplateEditorDialog } from '../components/TemplateEditorDialog';
import { bookingUrl } from '../links';
import { reminderOffsetsOf } from '../templates/drafts';
import {
  CHANNEL_LABELS,
  describeOffset,
  describeReminders,
  TEMPLATE_KEYS,
  previewVars,
  TEMPLATE_GROUPS,
  templateMeta,
  type TemplateKeyMeta,
} from '../templates/meta';
import { useSettingsAccess } from '../useSettingsAccess';

export default function TemplatesPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const { shop } = useShop();
  const query = useMessageTemplates();
  const shopSettings = useShopSettings();
  // ?edit=<key> opens a template's editor (links from Settings → Follow-ups).
  const [params, setParams] = useSearchParams();
  const editParam = params.get('edit');
  const editing: TemplateKey | null =
    TEMPLATE_KEYS.find((m) => m.key === editParam && !m.switchOnly)?.key ?? null;
  const setEditing = (key: TemplateKey | null) =>
    setParams(
      (prev) => {
        const next = new URLSearchParams(prev);
        if (key) next.set('edit', key);
        else next.delete('edit');
        return next;
      },
      { replace: true },
    );

  const vars = useMemo(
    () =>
      previewVars({
        name: shopSettings.data?.name ?? shop.name,
        phone: shopSettings.data?.phone ? formatPhone(shopSettings.data.phone) : null,
        reviewUrl: shopSettings.data?.review_url ?? null,
        bookingPageUrl: bookingUrl(shop.slug),
      }),
    [shopSettings.data, shop.name, shop.slug],
  );

  return (
    <SettingsSectionLayout section="templates" readOnly={readOnly}>
      <LapsedAutomationsNotice />
      <QueryView query={query} label="message templates">
        {(templates) => {
          const byKey = new Map<TemplateKey, MessageTemplate[]>();
          for (const t of templates) byKey.set(t.key, [...(byKey.get(t.key) ?? []), t]);
          return (
            <>
              <p className="text-muted text-sm">
                Automatic messages go out on every channel that’s on. Texts need an SMS number
                (Settings → SMS) and a customer who hasn’t opted out.
              </p>
              {TEMPLATE_GROUPS.map((group) => (
                <SectionCard key={group.label} title={group.label} flush>
                  <ul className="divide-line divide-y">
                    {group.keys.map((meta) => (
                      <TemplateRow
                        key={meta.key}
                        meta={meta}
                        rows={byKey.get(meta.key) ?? []}
                        canEdit={canEdit}
                        onOpen={() => setEditing(meta.key)}
                      />
                    ))}
                  </ul>
                </SectionCard>
              ))}
              {editing && (
                <TemplateEditorDialog
                  meta={templateMeta(editing)}
                  rows={byKey.get(editing) ?? []}
                  previewVars={vars}
                  canEdit={canEdit}
                  onClose={() => setEditing(null)}
                />
              )}
            </>
          );
        }}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function TemplateRow({
  meta,
  rows,
  canEdit,
  onOpen,
}: {
  meta: TemplateKeyMeta;
  rows: MessageTemplate[];
  canEdit: boolean;
  onOpen: () => void;
}) {
  const toast = useToast();
  const update = useUpdateTemplate();
  const offset = rows.find((r) => r.offset_minutes !== null)?.offset_minutes ?? null;
  const reminders = meta.multipleReminders ? reminderOffsetsOf(rows) : [];
  const timing = reminders.length > 1 ? describeReminders(reminders) : describeOffset(meta, offset);

  return (
    <li className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center">
      <div className="min-w-0 flex-1">
        <p className="text-ink text-sm font-medium">{meta.label}</p>
        <p className="text-muted text-xs">{meta.description}</p>
        {timing && (
          <p className="text-muted mt-1 inline-flex items-center gap-1 text-xs">
            <Clock className="size-3.5" aria-hidden="true" />
            {timing}
          </p>
        )}
        {meta.timingNote && <p className="text-muted mt-1 text-xs">{meta.timingNote}</p>}
      </div>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        {meta.channels.map((channel) => {
          const row = rows.find((r) => r.channel === channel);
          if (!row) {
            return (
              <Badge key={channel} tone="neutral">
                No {channel === 'sms' ? 'text' : 'email'}
              </Badge>
            );
          }
          return (
            <div key={channel} className="flex items-center gap-2">
              <span aria-hidden="true" className="text-muted text-xs font-medium">
                {channel === 'sms' ? 'Text' : 'Email'}
              </span>
              <Switch
                aria-label={`${meta.label}: ${CHANNEL_LABELS[channel]}`}
                checked={row.enabled}
                disabled={!canEdit || update.isPending}
                onCheckedChange={(enabled) =>
                  update.mutate(
                    { id: row.id, patch: { enabled } },
                    {
                      onSuccess: () =>
                        toast.success(
                          `${meta.label} ${channel === 'sms' ? 'text' : 'email'} ${enabled ? 'on' : 'off'}`,
                        ),
                      onError: (error) => toast.error(error),
                    },
                  )
                }
              />
            </div>
          );
        })}
        {!meta.switchOnly && (
          <Button
            variant="secondary"
            size="sm"
            leadingIcon={
              canEdit ? (
                <Pencil className="size-4" aria-hidden="true" />
              ) : (
                <Eye className="size-4" aria-hidden="true" />
              )
            }
            onClick={onOpen}
          >
            {canEdit ? 'Edit' : 'View'}
            <span className="sr-only"> {meta.label}</span>
          </Button>
        )}
      </div>
    </li>
  );
}
