import { zodResolver } from '@hookform/resolvers/zod';
import { KeyRound, Pencil, Plus, Send, Trash2, Webhook } from 'lucide-react';
import { useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { z } from 'zod';
import {
  Badge,
  Button,
  Card,
  Checkbox,
  ConfirmDialog,
  CopyField,
  Dialog,
  EmptyState,
  FormField,
  IconButton,
  Input,
  SectionCard,
  Switch,
  Table,
  useToast,
  type BadgeTone,
  type Column,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { formatDateTime, formatRelative } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { zOptionalText } from '@/lib/validation';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  MAX_WEBHOOK_ENDPOINTS,
  WEBHOOK_EVENT_LABELS,
  WEBHOOK_EVENTS,
  useCreateWebhookEndpoint,
  useDeleteWebhookEndpoint,
  useRotateWebhookSecret,
  useSendTestWebhook,
  useUpdateWebhookEndpoint,
  useWebhookDeliveries,
  useWebhookEndpoints,
  webhookUrlProblem,
  type WebhookDelivery,
  type WebhookEndpoint,
} from '../data/webhooks';

function eventLabel(event: string): string {
  return (WEBHOOK_EVENT_LABELS as Record<string, string>)[event] ?? event;
}

const DELIVERY_TONES: Record<string, BadgeTone> = {
  pending: 'neutral',
  delivering: 'info',
  succeeded: 'success',
  dead: 'danger',
};
const DELIVERY_LABELS: Record<string, string> = {
  pending: 'Waiting',
  delivering: 'Sending',
  succeeded: 'Delivered',
  dead: 'Gave up',
};

/** Owner/admin only (route guard: webhooks.manage). */
export default function WebhooksPage() {
  const endpoints = useWebhookEndpoints();
  const [editing, setEditing] = useState<{ endpoint: WebhookEndpoint | null } | null>(null);
  const [secret, setSecret] = useState<{ title: string; value: string } | null>(null);
  const atLimit = (endpoints.data?.length ?? 0) >= MAX_WEBHOOK_ENDPOINTS;

  return (
    <SettingsSectionLayout
      section="webhooks"
      actions={
        <Button
          leadingIcon={<Plus className="size-4" aria-hidden="true" />}
          disabled={atLimit}
          title={
            atLimit ? `A shop can have at most ${MAX_WEBHOOK_ENDPOINTS} endpoints.` : undefined
          }
          onClick={() => setEditing({ endpoint: null })}
        >
          Add endpoint
        </Button>
      }
    >
      <QueryView query={endpoints} label="webhook endpoints">
        {(rows) =>
          rows.length === 0 ? (
            <Card>
              <EmptyState
                icon={<Webhook aria-hidden="true" />}
                title="No webhook endpoints"
                description="Connect Zapier, Make or your own system: we POST a JSON message to your URL when something happens."
                action={
                  <Button variant="secondary" onClick={() => setEditing({ endpoint: null })}>
                    Add endpoint
                  </Button>
                }
              />
            </Card>
          ) : (
            <ul className="flex flex-col gap-4">
              {rows.map((endpoint) => (
                <li key={endpoint.id}>
                  <EndpointCard
                    endpoint={endpoint}
                    onEdit={() => setEditing({ endpoint })}
                    onSecret={(value) => setSecret({ title: 'New signing secret', value })}
                  />
                </li>
              ))}
            </ul>
          )
        }
      </QueryView>
      <Deliveries endpoints={endpoints.data ?? []} />
      <SignatureDocs />

      {editing && (
        <EndpointDialog
          endpoint={editing.endpoint}
          onClose={() => setEditing(null)}
          onCreated={(value) => setSecret({ title: 'Endpoint added', value })}
        />
      )}
      {secret && (
        <Dialog
          open
          onClose={() => setSecret(null)}
          title={secret.title}
          description="Copy the signing secret now: it won’t be shown again. Use it to check that messages really come from us."
          footer={<Button onClick={() => setSecret(null)}>Done</Button>}
        >
          <CopyField value={secret.value} label="Signing secret" copiedMessage="Secret copied" />
        </Dialog>
      )}
    </SettingsSectionLayout>
  );
}

function EndpointCard({
  endpoint,
  onEdit,
  onSecret,
}: {
  endpoint: WebhookEndpoint;
  onEdit: () => void;
  onSecret: (secret: string) => void;
}) {
  const toast = useToast();
  const { timezone } = useShop();
  const rotate = useRotateWebhookSecret();
  const test = useSendTestWebhook();
  const remove = useDeleteWebhookEndpoint();
  const [confirm, setConfirm] = useState<'rotate' | 'delete' | null>(null);
  const disabled = endpoint.disabled_at !== null;
  const live = endpoint.active && !disabled;

  return (
    <SectionCard
      title={<span className="font-mono text-sm break-all">{endpoint.url}</span>}
      description={endpoint.description ?? undefined}
      actions={
        <span className="flex items-center gap-1">
          <Badge tone={live ? 'success' : disabled ? 'danger' : 'neutral'} dot>
            {live ? 'On' : disabled ? 'Turned off after failures' : 'Off'}
          </Badge>
          <IconButton label={`Edit ${endpoint.url}`} icon={<Pencil />} size="sm" onClick={onEdit} />
          <IconButton
            label={`Delete ${endpoint.url}`}
            icon={<Trash2 />}
            size="sm"
            variant="danger"
            onClick={() => setConfirm('delete')}
          />
        </span>
      }
    >
      <div className="flex flex-col gap-3">
        <div className="flex flex-wrap gap-1">
          {endpoint.events.map((event) => (
            <Badge key={event} tone="info">
              {eventLabel(event)}
            </Badge>
          ))}
        </div>
        {disabled && (
          <p
            role="note"
            className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-xs"
          >
            Turned off on {formatDateTime(endpoint.disabled_at, timezone)} after{' '}
            {endpoint.consecutive_failures} failed deliveries in a row. Fix the receiving end, then
            edit the endpoint and turn it back on.
          </p>
        )}
        {!disabled && endpoint.consecutive_failures > 0 && (
          <p
            role="note"
            className="bg-warning-soft text-warning-ink rounded-control px-3 py-2 text-xs"
          >
            The last {endpoint.consecutive_failures} deliveries failed. After 25 failures in a row
            the endpoint is turned off.
          </p>
        )}
        <div className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            size="sm"
            leadingIcon={<Send className="size-4" aria-hidden="true" />}
            loading={test.isPending}
            disabled={!live}
            onClick={() =>
              test.mutate(endpoint.id, {
                onSuccess: () => toast.success('Test event queued', 'It’s sent within a minute.'),
                onError: (error) => toast.error(error),
              })
            }
          >
            Send a test
          </Button>
          <Button
            variant="ghost"
            size="sm"
            leadingIcon={<KeyRound className="size-4" aria-hidden="true" />}
            onClick={() => setConfirm('rotate')}
          >
            New signing secret
          </Button>
        </div>
      </div>
      <ConfirmDialog
        open={confirm === 'rotate'}
        onClose={() => setConfirm(null)}
        title="Make a new signing secret?"
        description="The current secret stops working right away. Update your receiver with the new one, or it will reject our messages."
        confirmLabel="Make a new secret"
        loading={rotate.isPending}
        onConfirm={async () => {
          try {
            const secret = await rotate.mutateAsync(endpoint.id);
            setConfirm(null);
            onSecret(secret);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
      <ConfirmDialog
        open={confirm === 'delete'}
        onClose={() => setConfirm(null)}
        tone="danger"
        title="Delete this endpoint?"
        description="No more events are sent to it, and its delivery history is removed."
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          try {
            await remove.mutateAsync(endpoint.id);
            toast.success('Endpoint deleted');
            setConfirm(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}

const endpointSchema = z
  .object({
    url: z.string().trim(),
    description: zOptionalText(200),
    events: z.array(z.string()).min(1, 'Choose at least one event.'),
    active: z.boolean(),
  })
  .superRefine((v, ctx) => {
    const problem = webhookUrlProblem(v.url);
    if (problem) ctx.addIssue({ code: 'custom', path: ['url'], message: problem });
  });
type EndpointInput = z.input<typeof endpointSchema>;
type EndpointValues = z.output<typeof endpointSchema>;

function EndpointDialog({
  endpoint,
  onClose,
  onCreated,
}: {
  endpoint: WebhookEndpoint | null;
  onClose: () => void;
  onCreated: (secret: string) => void;
}) {
  const toast = useToast();
  const create = useCreateWebhookEndpoint();
  const update = useUpdateWebhookEndpoint();
  const saving = create.isPending || update.isPending;
  const {
    register,
    control,
    handleSubmit,
    setError,
    formState: { errors },
  } = useForm<EndpointInput, unknown, EndpointValues>({
    resolver: zodResolver(endpointSchema),
    defaultValues: {
      url: endpoint?.url ?? '',
      description: endpoint?.description ?? '',
      events: endpoint?.events ?? [...WEBHOOK_EVENTS],
      active: endpoint ? endpoint.active && endpoint.disabled_at === null : true,
    },
  });

  const onSubmit = handleSubmit(async (v) => {
    try {
      if (endpoint) {
        await update.mutateAsync({
          id: endpoint.id,
          url: v.url,
          events: v.events,
          description: v.description,
          active: v.active,
        });
        toast.success('Endpoint saved');
        onClose();
      } else {
        const created = await create.mutateAsync({
          url: v.url,
          events: v.events,
          description: v.description,
        });
        onClose();
        onCreated(created.secret);
      }
    } catch (error) {
      const appError = toAppError(error);
      if (appError.code === '22023' && /url|host|https/i.test(appError.message)) {
        setError('url', { message: appError.message });
        return;
      }
      toast.error(appError);
    }
  });

  const formId = 'webhook-endpoint-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!saving}
      size="lg"
      title={endpoint ? 'Edit endpoint' : 'New webhook endpoint'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={saving}>
            {endpoint ? 'Save' : 'Add endpoint'}
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="flex flex-col gap-4"
      >
        <FormField
          label="URL"
          required
          error={errors.url?.message}
          help="An https address that accepts POST requests, e.g. a Zapier “Catch Hook” URL."
        >
          <Input
            type="url"
            inputMode="url"
            autoComplete="off"
            className="font-mono"
            {...register('url')}
          />
        </FormField>
        <FormField
          label="Description"
          error={errors.description?.message}
          help="Optional, for you."
        >
          <Input maxLength={200} {...register('description')} />
        </FormField>
        <Controller
          control={control}
          name="events"
          render={({ field }) => (
            <fieldset className="flex flex-col gap-2">
              <legend className="text-ink mb-1 text-sm font-medium">Events to send</legend>
              <div className="grid gap-2 sm:grid-cols-2">
                {WEBHOOK_EVENTS.map((event) => (
                  <Checkbox
                    key={event}
                    label={WEBHOOK_EVENT_LABELS[event]}
                    description={<span className="font-mono">{event}</span>}
                    checked={field.value.includes(event)}
                    onChange={(e) =>
                      field.onChange(
                        e.target.checked
                          ? WEBHOOK_EVENTS.filter((ev) => ev === event || field.value.includes(ev))
                          : field.value.filter((ev) => ev !== event),
                      )
                    }
                  />
                ))}
              </div>
              {errors.events?.message && (
                <p role="alert" className="text-danger-ink text-xs font-medium">
                  {errors.events.message}
                </p>
              )}
            </fieldset>
          )}
        />
        {endpoint && (
          <Controller
            control={control}
            name="active"
            render={({ field }) => (
              <Switch
                label="Endpoint is on"
                description={
                  endpoint.disabled_at
                    ? 'It was turned off after repeated failures. Turning it on resets the failure count.'
                    : 'Off: events are not sent to it.'
                }
                checked={field.value}
                onCheckedChange={field.onChange}
              />
            )}
          />
        )}
      </form>
    </Dialog>
  );
}

function Deliveries({ endpoints }: { endpoints: readonly WebhookEndpoint[] }) {
  const { timezone } = useShop();
  const query = useWebhookDeliveries();
  const urls = new Map(endpoints.map((e) => [e.id, e.url]));
  const columns: Column<WebhookDelivery>[] = [
    {
      key: 'event',
      header: 'Event',
      primary: true,
      cell: (d) => (
        <span className="flex flex-col">
          <span>{eventLabel(d.event)}</span>
          <span className="text-muted truncate font-mono text-xs">
            {urls.get(d.endpoint_id) ?? ''}
          </span>
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      cell: (d) => (
        <Badge tone={DELIVERY_TONES[d.status] ?? 'neutral'}>
          {DELIVERY_LABELS[d.status] ?? d.status}
        </Badge>
      ),
    },
    {
      key: 'code',
      header: 'Response',
      cell: (d) =>
        d.last_status_code !== null ? (
          <span className="tabular-nums">{d.last_status_code}</span>
        ) : d.last_error ? (
          <span className="text-muted text-xs">{d.last_error}</span>
        ) : (
          '—'
        ),
    },
    { key: 'attempts', header: 'Tries', align: 'right', cell: (d) => d.attempts },
    {
      key: 'when',
      header: 'When',
      cell: (d) =>
        d.status === 'pending' && d.attempts > 0
          ? `Retry ${formatRelative(d.next_attempt_at)}`
          : formatDateTime(d.delivered_at ?? d.created_at, timezone),
    },
  ];
  return (
    <SectionCard
      title="Recent deliveries"
      description="The last 50 events sent to your endpoints. Failed deliveries are retried after 1 minute, 5 minutes, 30 minutes, 2, 6, 12 and 24 hours."
      flush
    >
      <QueryView query={query} label="deliveries">
        {(rows) =>
          rows.length === 0 ? (
            <EmptyState compact title="Nothing sent yet" description="Deliveries show up here." />
          ) : (
            <Table
              caption="Recent webhook deliveries"
              columns={columns}
              rows={rows}
              getRowId={(d) => d.id}
            />
          )
        }
      </QueryView>
    </SectionCard>
  );
}

function SignatureDocs() {
  return (
    <SectionCard title="Checking the signature" level={3}>
      <div className="text-muted flex flex-col gap-2 text-sm">
        <p>
          Each delivery is a POST with a JSON body and these headers:{' '}
          <code className="text-ink">X-DetailCRM-Event</code> (the event),{' '}
          <code className="text-ink">X-DetailCRM-Delivery</code> (a unique id — ignore repeats) and{' '}
          <code className="text-ink">X-DetailCRM-Signature</code>, like{' '}
          <code className="text-ink">t=1767225600,v1=5257a8…</code>.
        </p>
        <p>
          To verify it, compute an HMAC-SHA256 with your signing secret over{' '}
          <code className="text-ink">t + &quot;.&quot; + the raw body</code> and compare the hex
          result with <code className="text-ink">v1</code>. Reject messages whose{' '}
          <code className="text-ink">t</code> is more than 5 minutes old. Answer with any 2xx status
          within 10 seconds; anything else counts as a failure and is retried.
        </p>
        <p>
          Bodies contain the job, customer (name, email, phone), payment or membership involved —
          never card details or internal notes.
        </p>
      </div>
    </SectionCard>
  );
}
