/**
 * Outbound webhooks (P-27): webhook_endpoints / webhook_deliveries (0081 /
 * 0089), owners/admins only. Writes go through RPCs; the signing secret is
 * never readable — it is returned once by create / rotate.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { useShop } from '@/features/shop/shopContext';
import { unwrap, type Row } from '@/lib/db';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';
import { unwrapList } from './shared';

export const WEBHOOK_EVENTS = [
  'booking_created',
  'booking_confirmed',
  'on_the_way',
  'job_completed',
  'payment_succeeded',
  'form_signed',
  'membership_activated',
] as const;
export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];

export const WEBHOOK_EVENT_LABELS: Record<WebhookEvent | 'test', string> = {
  booking_created: 'Booking created',
  booking_confirmed: 'Booking confirmed',
  on_the_way: 'Technician on the way',
  job_completed: 'Job completed',
  payment_succeeded: 'Payment received',
  form_signed: 'Form signed',
  membership_activated: 'Membership started',
  test: 'Test',
};

/** Most endpoints per shop (create_webhook_endpoint). */
export const MAX_WEBHOOK_ENDPOINTS = 20;

export type WebhookEndpoint = Pick<
  Row<'webhook_endpoints'>,
  | 'id'
  | 'url'
  | 'description'
  | 'events'
  | 'active'
  | 'consecutive_failures'
  | 'disabled_at'
  | 'created_at'
>;

export type WebhookDelivery = Pick<
  Row<'webhook_deliveries'>,
  | 'id'
  | 'endpoint_id'
  | 'event'
  | 'status'
  | 'attempts'
  | 'next_attempt_at'
  | 'last_status_code'
  | 'last_error'
  | 'delivered_at'
  | 'created_at'
>;

export const webhookKeys = {
  all: (shopId: string) => [...settingsKeys.all(shopId), 'webhooks'] as const,
  endpoints: (shopId: string) => [...webhookKeys.all(shopId), 'endpoints'] as const,
  deliveries: (shopId: string) => [...webhookKeys.all(shopId), 'deliveries'] as const,
};

export function useWebhookEndpoints() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: webhookKeys.endpoints(shopId),
    queryFn: async (): Promise<WebhookEndpoint[]> =>
      unwrapList(
        await supabase
          .from('webhook_endpoints')
          .select(
            'id, url, description, events, active, consecutive_failures, disabled_at, created_at',
          )
          .eq('shop_id', shopId)
          .order('created_at'),
      ),
  });
}

/** The latest 50 deliveries (every endpoint). Refreshes every 15 s while open. */
export function useWebhookDeliveries() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: webhookKeys.deliveries(shopId),
    refetchInterval: 15_000,
    queryFn: async (): Promise<WebhookDelivery[]> =>
      unwrapList(
        await supabase
          .from('webhook_deliveries')
          .select(
            'id, endpoint_id, event, status, attempts, next_attempt_at, last_status_code, last_error, delivered_at, created_at',
          )
          .eq('shop_id', shopId)
          .order('created_at', { ascending: false })
          .limit(50),
      ),
  });
}

const secretResultSchema = z.object({ secret: z.string() });
const createResultSchema = z.object({ id: z.string(), secret: z.string() });

export interface WebhookEndpointInput {
  url: string;
  events: string[];
  description: string | null;
}

function useInvalidateWebhooks() {
  const { shopId } = useShop();
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: webhookKeys.all(shopId) });
}

export function useCreateWebhookEndpoint() {
  const { shopId } = useShop();
  const invalidate = useInvalidateWebhooks();
  return useMutation({
    mutationFn: async (input: WebhookEndpointInput) =>
      createResultSchema.parse(
        unwrap(
          await supabase.rpc('create_webhook_endpoint', {
            p_shop_id: shopId,
            p_url: input.url,
            p_events: input.events,
            ...(input.description ? { p_description: input.description } : {}),
          }),
        ),
      ),
    onSettled: invalidate,
  });
}

export function useUpdateWebhookEndpoint() {
  const invalidate = useInvalidateWebhooks();
  return useMutation({
    mutationFn: async (input: WebhookEndpointInput & { id: string; active: boolean }) => {
      unwrap(
        await supabase.rpc('update_webhook_endpoint', {
          p_endpoint_id: input.id,
          p_url: input.url,
          p_events: input.events,
          p_active: input.active,
          ...(input.description ? { p_description: input.description } : {}),
        }),
      );
    },
    onSettled: invalidate,
  });
}

export function useRotateWebhookSecret() {
  const invalidate = useInvalidateWebhooks();
  return useMutation({
    mutationFn: async (id: string) =>
      secretResultSchema.parse(
        unwrap(await supabase.rpc('rotate_webhook_secret', { p_endpoint_id: id })),
      ).secret,
    onSettled: invalidate,
  });
}

export function useDeleteWebhookEndpoint() {
  const invalidate = useInvalidateWebhooks();
  return useMutation({
    mutationFn: async (id: string) => {
      unwrap(await supabase.rpc('delete_webhook_endpoint', { p_endpoint_id: id }));
    },
    onSettled: invalidate,
  });
}

export function useSendTestWebhook() {
  const invalidate = useInvalidateWebhooks();
  return useMutation({
    mutationFn: async (id: string): Promise<string> =>
      unwrap(await supabase.rpc('send_test_webhook', { p_endpoint_id: id })) ?? '',
    onSettled: invalidate,
  });
}

/**
 * Client-side URL check mirroring comms_webhook_url (0089): https, a host
 * NAME (no IP literals, no local / internal names), no credentials. Returns
 * a message or null. The server re-checks.
 */
export function webhookUrlProblem(value: string): string | null {
  const text = value.trim();
  if (text === '') return 'Enter the URL to send events to.';
  if (text.length > 2000) return 'Use 2,000 characters or fewer.';
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return 'Enter a full URL, like https://hooks.zapier.com/…';
  }
  if (url.protocol !== 'https:') return 'The URL must start with https://.';
  if (url.username || url.password) return 'Remove the user name or password from the URL.';
  const host = url.hostname.toLowerCase().replace(/\.$/, '');
  if (host.startsWith('[') || /^[\d.]+$/.test(host)) {
    return 'Use a host name, not an IP address.';
  }
  const labels = host.split('.');
  const last = labels[labels.length - 1] ?? '';
  if (
    labels.length < 2 ||
    /^(\d+|0x[0-9a-f]*)$/i.test(last) ||
    labels.some((label) => /^0x[0-9a-f]+$/i.test(label))
  ) {
    return 'Use a host name, not an IP address.';
  }
  if (host === 'localhost' || /\.(local|internal|localhost|lan|home)$/.test(host)) {
    return 'Use a public host name.';
  }
  return null;
}
