import { Badge, type BadgeTone } from './Badge';

/**
 * Every workflow status in the product (SPEC §4) → label + tone, in one map
 * so web screens agree. Amber (money) is used only where money is owed.
 */
export const STATUS_MAP = {
  job: {
    requested: { label: 'Requested', tone: 'warning' },
    scheduled: { label: 'Scheduled', tone: 'info' },
    confirmed: { label: 'Confirmed', tone: 'info' },
    en_route: { label: 'On the way', tone: 'info' },
    in_progress: { label: 'In progress', tone: 'info' },
    completed: { label: 'Completed', tone: 'success' },
    cancelled: { label: 'Cancelled', tone: 'neutral' },
    no_show: { label: 'No-show', tone: 'danger' },
  },
  quote: {
    draft: { label: 'Draft', tone: 'neutral' },
    sent: { label: 'Sent', tone: 'info' },
    viewed: { label: 'Viewed', tone: 'info' },
    approved: { label: 'Approved', tone: 'success' },
    declined: { label: 'Declined', tone: 'danger' },
    expired: { label: 'Expired', tone: 'neutral' },
    converted: { label: 'Converted', tone: 'success' },
  },
  invoice: {
    draft: { label: 'Draft', tone: 'neutral' },
    open: { label: 'Open', tone: 'money' },
    partially_paid: { label: 'Partially paid', tone: 'money' },
    paid: { label: 'Paid', tone: 'success' },
    void: { label: 'Void', tone: 'neutral' },
  },
  payment: {
    pending: { label: 'Pending', tone: 'warning' },
    succeeded: { label: 'Succeeded', tone: 'success' },
    failed: { label: 'Failed', tone: 'danger' },
    cancelled: { label: 'Cancelled', tone: 'neutral' },
    refunded: { label: 'Refunded', tone: 'neutral' },
    partially_refunded: { label: 'Partially refunded', tone: 'warning' },
  },
  membership: {
    incomplete: { label: 'Incomplete', tone: 'warning' },
    active: { label: 'Active', tone: 'success' },
    past_due: { label: 'Past due', tone: 'danger' },
    cancelled: { label: 'Cancelled', tone: 'neutral' },
  },
  message: {
    queued: { label: 'Queued', tone: 'neutral' },
    sending: { label: 'Sending', tone: 'info' },
    sent: { label: 'Sent', tone: 'info' },
    delivered: { label: 'Delivered', tone: 'success' },
    failed: { label: 'Failed', tone: 'danger' },
    received: { label: 'Received', tone: 'info' },
  },
} as const satisfies Record<string, Record<string, { label: string; tone: BadgeTone }>>;

export type StatusKind = keyof typeof STATUS_MAP;
export type StatusOf<K extends StatusKind> = keyof (typeof STATUS_MAP)[K] & string;

export function statusLabel(kind: StatusKind, status: string): string {
  const entry = (STATUS_MAP[kind] as Record<string, { label: string; tone: BadgeTone }>)[status];
  return entry?.label ?? humanize(status);
}

export function statusTone(kind: StatusKind, status: string): BadgeTone {
  const entry = (STATUS_MAP[kind] as Record<string, { label: string; tone: BadgeTone }>)[status];
  return entry?.tone ?? 'neutral';
}

function humanize(value: string): string {
  const text = value.replace(/_/g, ' ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}

export interface StatusBadgeProps {
  kind: StatusKind;
  /** Unknown statuses render humanized in a neutral badge (never crash). */
  status: string;
  className?: string;
}

export function StatusBadge({ kind, status, className }: StatusBadgeProps) {
  return (
    <Badge tone={statusTone(kind, status)} dot className={className}>
      {statusLabel(kind, status)}
    </Badge>
  );
}
