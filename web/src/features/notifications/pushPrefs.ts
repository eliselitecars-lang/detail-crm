/**
 * Push preferences (P-2) — pure helpers. The server pushes a kind only when
 * the recipient's role may read it (notification_kind_for_managers, 0082):
 * every member gets general notices and their own work (jobs assigned /
 * rescheduled, tasks); owners, admins and managers get every kind.
 */
import { Constants } from '@/lib/database.types';
import type { ShopRole } from '@/features/shop/permissions';
import type { NotificationKind } from './links';

export const ALL_KINDS: readonly NotificationKind[] = Constants.public.Enums.notification_kind;

/** Kinds every member may read (and so be pushed). */
export const MEMBER_KINDS: readonly NotificationKind[] = [
  'job_assigned',
  'job_rescheduled',
  'task_assigned',
  'task_due',
  'general',
];

/** The kinds this role can receive, in display order. */
export function pushableKinds(role: ShopRole): NotificationKind[] {
  if (role === 'technician') return [...MEMBER_KINDS];
  return [...MEMBER_KINDS, ...ALL_KINDS.filter((k) => !MEMBER_KINDS.includes(k))];
}

/** What is switched on: a member without a saved row gets every kind. */
export function enabledKinds(saved: readonly NotificationKind[] | null | undefined) {
  return new Set<NotificationKind>(saved ?? ALL_KINDS);
}

/**
 * The push_kinds to save: the visible selection plus the saved choice for
 * kinds this role can't see (so a later promotion keeps what was set).
 */
export function nextPushKinds(
  saved: readonly NotificationKind[] | null | undefined,
  visible: readonly NotificationKind[],
  selected: ReadonlySet<NotificationKind>,
): NotificationKind[] {
  const before = enabledKinds(saved);
  return ALL_KINDS.filter((k) => (visible.includes(k) ? selected.has(k) : before.has(k)));
}

/** True while pushes are paused. */
export function isMuted(mutedUntil: string | null | undefined, now = new Date()): boolean {
  return mutedUntil !== null && mutedUntil !== undefined && Date.parse(mutedUntil) > now.getTime();
}
