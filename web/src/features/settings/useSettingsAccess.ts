import { useCan } from '@/features/shop/useCan';

/**
 * SPEC §3: owner/admin edit shop settings; managers read them (and manage
 * blocked times, which are part of the calendar); technicians have no
 * settings access at all (the route guard stops them first).
 */
export function useSettingsAccess() {
  const canEdit = useCan('settings.manage');
  const canManageBlockedTimes = useCan('blockedTimes.manage');
  return { canEdit, canManageBlockedTimes, readOnly: !canEdit };
}
