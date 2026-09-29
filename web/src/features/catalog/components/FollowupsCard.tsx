import { Mail, MessageSquare, Pencil, Plus, Repeat, Trash2 } from 'lucide-react';
import { useId, useState } from 'react';
import { Link } from 'react-router';
import {
  Badge,
  Button,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  IconButton,
  Input,
  LoadingState,
  RadioGroup,
  SectionCard,
  Select,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import {
  BODY_LIMITS,
  CHANNEL_LABELS,
  SERVICE_FOLLOWUP_PLACEHOLDERS,
  previewVars,
} from '@/features/settings/templates/meta';
import { placeholdersIn, renderTemplate, smsSegments } from '@/features/settings/templates/render';
import { useShopSettings } from '@/features/settings/api';
import { MarketingAddressNotice } from '@/features/settings/components/MarketingAddressNotice';
import { hasMailingAddress } from '@/features/settings/marketingAddress';
import {
  useDeleteFollowup,
  useFollowupSwitches,
  useSaveFollowup,
  useServiceFollowups,
  useToggleFollowup,
  type ServiceFollowupRow,
} from '../api';
import {
  daysToOffsetParts,
  describeFollowupOffset,
  MAX_FOLLOWUPS_PER_CHANNEL,
  OFFSET_UNIT_LABELS,
  offsetPartsToDays,
  type OffsetUnit,
  type ServiceRow,
} from '../model';

type Channel = 'sms' | 'email';
const KNOWN_PLACEHOLDERS = new Set(SERVICE_FOLLOWUP_PLACEHOLDERS.map((p) => p.name));

/**
 * Maintenance follow-ups (P-4): messages sent a set time after a completed
 * job with this service ("time for your coating check-up"). Each channel's
 * `service_followup` template is the shop-wide switch; the wording lives here.
 */
export function FollowupsCard({ service, canManage }: { service: ServiceRow; canManage: boolean }) {
  const toast = useToast();
  const followups = useServiceFollowups(service.id);
  const switches = useFollowupSwitches();
  const toggle = useToggleFollowup(service.id);
  const remove = useDeleteFollowup(service.id);
  const shopSettings = useShopSettings();
  const [editing, setEditing] = useState<ServiceFollowupRow | 'new' | null>(null);
  const [deleting, setDeleting] = useState<ServiceFollowupRow | null>(null);
  const rows = followups.data ?? [];
  const full = (channel: Channel) =>
    rows.filter((r) => r.channel === channel).length >= MAX_FOLLOWUPS_PER_CHANNEL;
  const canAdd = canManage && !(full('sms') && full('email'));

  let body;
  if (followups.isPending)
    body = <LoadingState variant="rows" rows={2} label="Loading follow-ups…" />;
  else if (followups.error)
    body = (
      <ErrorState
        compact
        error={followups.error}
        title="Couldn’t load follow-ups"
        onRetry={() => void followups.refetch()}
        retrying={followups.isRefetching}
      />
    );
  else if (rows.length === 0)
    body = (
      <EmptyState
        compact
        icon={<Repeat aria-hidden="true" />}
        title="No follow-ups"
        description="Remind customers when this service is due again — for example a maintenance wash 3 months after a coating."
        action={
          canManage ? (
            <Button size="sm" leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              Add follow-up
            </Button>
          ) : undefined
        }
      />
    );
  else
    body = (
      <ul className="divide-line divide-y" aria-label="Follow-up messages">
        {rows.map((row) => (
          <li key={row.id} className="flex items-start gap-3 px-4 py-3 sm:px-5">
            <span className="bg-surface-2 text-muted mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full [&_svg]:size-4">
              {row.channel === 'sms' ? (
                <MessageSquare aria-hidden="true" />
              ) : (
                <Mail aria-hidden="true" />
              )}
            </span>
            <div className="min-w-0 flex-1">
              <p className="text-ink text-sm font-medium">
                {describeFollowupOffset(row.offset_days)}
                <span className="text-muted font-normal"> · {CHANNEL_LABELS[row.channel]}</span>
              </p>
              {row.subject && <p className="text-ink truncate text-sm">{row.subject}</p>}
              <p className="text-muted line-clamp-2 text-xs break-words whitespace-pre-line">
                {row.body}
              </p>
            </div>
            {canManage ? (
              <div className="flex shrink-0 items-center gap-1">
                <Switch
                  aria-label={`Send ${describeFollowupOffset(row.offset_days)} by ${CHANNEL_LABELS[row.channel]}`}
                  checked={row.enabled}
                  disabled={toggle.isPending}
                  onCheckedChange={(enabled) =>
                    toggle.mutate(
                      { id: row.id, enabled },
                      { onError: (error) => toast.error(error) },
                    )
                  }
                />
                <IconButton
                  label="Edit follow-up"
                  icon={<Pencil className="size-4" />}
                  size="sm"
                  onClick={() => setEditing(row)}
                />
                <IconButton
                  label="Delete follow-up"
                  icon={<Trash2 className="size-4" />}
                  size="sm"
                  variant="danger"
                  onClick={() => setDeleting(row)}
                />
              </div>
            ) : (
              !row.enabled && <Badge tone="neutral">Off</Badge>
            )}
          </li>
        ))}
      </ul>
    );

  const off =
    switches.data && rows.some((r) => r.enabled && !switches.data[r.channel])
      ? (['sms', 'email'] as const).filter(
          (c) => !switches.data[c] && rows.some((r) => r.enabled && r.channel === c),
        )
      : [];

  // 0119: these emails are marketing, never sent without the shop's mailing address.
  const emailsWithoutAddress =
    shopSettings.data !== undefined &&
    !hasMailingAddress(shopSettings.data) &&
    switches.data?.email === true &&
    rows.some((r) => r.enabled && r.channel === 'email');

  return (
    <>
      <SectionCard
        title="Follow-up messages"
        description="Sent after a completed job with this item, to customers who agreed to marketing messages on that channel."
        flush
        actions={
          canAdd && rows.length > 0 ? (
            <Button size="sm" leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              Add follow-up
            </Button>
          ) : undefined
        }
      >
        {off.length > 0 && (
          <p className="bg-warning-soft text-warning-ink border-line border-b px-4 py-2 text-sm sm:px-5">
            Service follow-ups by {off.map((c) => CHANNEL_LABELS[c].toLowerCase()).join(' and ')}{' '}
            are turned off for the whole shop, so these won’t be sent.{' '}
            <Link
              to="/app/settings/templates?edit=service_followup"
              className="font-medium underline"
            >
              Turn them on in Templates
            </Link>
          </p>
        )}
        {emailsWithoutAddress && (
          <MarketingAddressNotice className="border-line rounded-none border-x-0 border-t-0 border-b px-4 sm:px-5">
            The email follow-ups here are on but aren’t being sent.
          </MarketingAddressNotice>
        )}
        {body}
      </SectionCard>
      {editing !== null && (
        <FollowupDialog
          service={service}
          followup={editing === 'new' ? null : editing}
          full={full}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        loading={remove.isPending}
        title="Delete this follow-up?"
        description="Follow-ups already sent stay in the message history. Scheduled ones for past visits won’t go out."
        confirmLabel="Delete"
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Follow-up deleted');
          } catch (error) {
            toast.error(error);
          } finally {
            setDeleting(null);
          }
        }}
      />
    </>
  );
}

function FollowupDialog({
  service,
  followup,
  full,
  onClose,
}: {
  service: ServiceRow;
  followup: ServiceFollowupRow | null;
  full: (channel: Channel) => boolean;
  onClose: () => void;
}) {
  const toast = useToast();
  const { shop } = useShop();
  const save = useSaveFollowup(service.id);
  const formId = useId();
  const initialChannel: Channel = followup?.channel ?? (full('sms') ? 'email' : 'sms');
  const [channel, setChannel] = useState<Channel>(initialChannel);
  const initialOffset = daysToOffsetParts(followup?.offset_days ?? 90);
  const [amount, setAmount] = useState(followup ? initialOffset.amount : '3');
  const [unit, setUnit] = useState<OffsetUnit>(followup ? initialOffset.unit : 'months');
  const [subject, setSubject] = useState(followup?.subject ?? '');
  const [body, setBody] = useState(followup?.body ?? '');
  const [enabled, setEnabled] = useState(followup?.enabled ?? true);
  const [errors, setErrors] = useState<
    Partial<Record<'offset' | 'subject' | 'body' | 'channel', string>>
  >({});

  const vars = previewVars({
    name: shop.name,
    phone: null,
    reviewUrl: null,
    bookingPageUrl: `${window.location.origin}/book/${shop.slug}`,
  });
  const unknown = placeholdersIn(`${subject} ${body}`).filter((p) => !KNOWN_PLACEHOLDERS.has(p));
  const segments = channel === 'sms' ? smsSegments(renderTemplate(body, vars)) : null;
  const channelFull = !followup || followup.channel !== channel ? full(channel) : false;

  const submit = async () => {
    const next: typeof errors = {};
    const offset = offsetPartsToDays(amount, unit);
    if (offset.error) next.offset = offset.error;
    if (channelFull) {
      next.channel = `This item already has ${MAX_FOLLOWUPS_PER_CHANNEL} ${CHANNEL_LABELS[channel].toLowerCase()} follow-ups.`;
    }
    if (channel === 'email') {
      const s = subject.trim();
      if (s === '') next.subject = 'Subject is required for email.';
      else if (s.length > 200) next.subject = 'Subject must be 200 characters or fewer.';
    }
    const b = body.trim();
    if (b === '') next.body = 'Write the message.';
    else if (body.length > BODY_LIMITS[channel]) {
      next.body = `Keep it to ${BODY_LIMITS[channel].toLocaleString('en-US')} characters or fewer.`;
    }
    setErrors(next);
    if (Object.keys(next).length > 0 || offset.days === null) return;
    try {
      await save.mutateAsync({
        ...(followup ? { id: followup.id } : {}),
        channel,
        offsetDays: offset.days,
        subject: channel === 'email' ? subject.trim() : null,
        body: b,
        enabled,
      });
      toast.success(followup ? 'Follow-up saved' : 'Follow-up added');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      title={followup ? 'Edit follow-up' : `New follow-up for ${service.name}`}
      size="lg"
      footer={
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {followup ? 'Save follow-up' : 'Add follow-up'}
          </Button>
        </div>
      }
    >
      <form
        id={formId}
        noValidate
        className="flex flex-col gap-4"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <RadioGroup<Channel>
          label="Send by"
          value={channel}
          onChange={(next) => {
            setChannel(next);
            setErrors((prev) => ({ ...prev, channel: undefined }));
          }}
          orientation="horizontal"
          options={[
            { value: 'sms', label: CHANNEL_LABELS.sms },
            { value: 'email', label: CHANNEL_LABELS.email },
          ]}
        />
        {errors.channel && (
          <p role="alert" className="text-danger-ink -mt-2 text-xs font-medium">
            {errors.channel}
          </p>
        )}
        <div className="grid gap-4 sm:grid-cols-[8rem_1fr]">
          <FormField label="After" required error={errors.offset}>
            <Input
              inputMode="numeric"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              maxLength={4}
            />
          </FormField>
          <FormField label="Unit" help="Counted from the day the job was completed.">
            <Select
              value={unit}
              onChange={(e) => setUnit(e.target.value as OffsetUnit)}
              options={(['days', 'weeks', 'months'] as const).map((u) => ({
                value: u,
                label: OFFSET_UNIT_LABELS[u],
              }))}
            />
          </FormField>
        </div>
        {channel === 'email' && (
          <FormField label="Subject" required error={errors.subject}>
            <Input value={subject} maxLength={200} onChange={(e) => setSubject(e.target.value)} />
          </FormField>
        )}
        <FormField
          label="Message"
          required
          error={errors.body}
          help={
            <>
              Placeholders: {SERVICE_FOLLOWUP_PLACEHOLDERS.map((p) => `{{${p.name}}}`).join(' ')}.{' '}
              {'{{rebook_link}}'} opens your booking page with this item already chosen.
            </>
          }
        >
          <Textarea
            rows={5}
            value={body}
            maxLength={BODY_LIMITS[channel]}
            onChange={(e) => setBody(e.target.value)}
          />
        </FormField>
        {unknown.length > 0 && (
          <p className="text-warning-ink text-xs" role="status">
            Unknown placeholder{unknown.length > 1 ? 's' : ''}:{' '}
            {unknown.map((p) => `{{${p}}}`).join(', ')} — they’ll be left blank.
          </p>
        )}
        <div className="rounded-control border-line bg-surface-2 flex flex-col gap-1 border p-3">
          <p className="text-muted text-xs font-medium">Preview</p>
          {channel === 'email' && subject.trim() && (
            <p className="text-ink text-sm font-medium">{renderTemplate(subject, vars)}</p>
          )}
          <p className="text-ink text-sm break-words whitespace-pre-line">
            {body.trim() ? renderTemplate(body, vars) : 'Your message appears here.'}
          </p>
          {segments && body.trim() && (
            <p className="text-subtle text-xs">
              About {segments.segments} text message{segments.segments === 1 ? '' : 's'}
              {segments.unicode ? ' (special characters use more)' : ''}.
            </p>
          )}
        </div>
        <Switch
          label="On"
          description="Turn off to keep the wording without sending it."
          checked={enabled}
          onCheckedChange={setEnabled}
        />
      </form>
    </Dialog>
  );
}
