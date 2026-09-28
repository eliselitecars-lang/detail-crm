import { BellRing, Smartphone } from 'lucide-react';
import { useState, type FormEvent } from 'react';
import {
  Button,
  Checkbox,
  DateInput,
  ErrorState,
  FormField,
  LoadingState,
  SectionCard,
  useToast,
} from '@/components/ui';
import { useAuth } from '@/features/auth/authContext';
import { useShop } from '@/features/shop/shopContext';
import {
  addLocalDays,
  formatDateTime,
  shopLocalToUtcIso,
  shopToday,
  utcToShopLocal,
} from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import {
  usePushDeviceCount,
  usePushPrefs,
  useSavePushPrefs,
  useSendTestPush,
  type PushPrefs,
} from '../api';
import { KIND_LABELS, type NotificationKind } from '../links';
import { enabledKinds, isMuted, nextPushKinds, pushableKinds } from '../pushPrefs';

/**
 * "Push notifications (iPhone app)": which notification kinds the member's
 * iPhones show as pushes, and an optional pause. The in-app list is never
 * affected. Web push is not offered (the iPhone app delivers pushes).
 */
export function PushPrefsCard() {
  const { shopId, memberId } = useShop();
  const prefs = usePushPrefs(shopId, memberId);
  return (
    <SectionCard
      title="Push notifications (iPhone app)"
      description="Choose what your iPhone shows as a notification. This page always lists everything."
    >
      {prefs.isPending ? (
        <LoadingState variant="rows" rows={3} label="Loading push settings…" />
      ) : prefs.isError ? (
        <ErrorState
          compact
          error={prefs.error}
          title="Couldn’t load your push settings"
          onRetry={() => void prefs.refetch()}
          retrying={prefs.isRefetching}
        />
      ) : (
        <PushPrefsForm key={JSON.stringify(prefs.data)} saved={prefs.data} />
      )}
    </SectionCard>
  );
}

function PushPrefsForm({ saved }: { saved: PushPrefs | null }) {
  const { shopId, memberId, role, timezone } = useShop();
  const { user } = useAuth();
  const userId = user?.id ?? '';
  const toast = useToast();
  const save = useSavePushPrefs(shopId, memberId);
  const visible = pushableKinds(role);
  const [selected, setSelected] = useState<Set<NotificationKind>>(() => {
    const on = enabledKinds(saved?.push_kinds);
    return new Set(visible.filter((k) => on.has(k)));
  });
  const [muteDate, setMuteDate] = useState(() =>
    saved && isMuted(saved.muted_until) && saved.muted_until
      ? utcToShopLocal(saved.muted_until, timezone).date
      : '',
  );
  const [muteError, setMuteError] = useState<string | null>(null);
  const today = shopToday(timezone);
  const tomorrow = addLocalDays(today, 1);
  const mutedNow = saved !== null && isMuted(saved.muted_until);

  const toggle = (kind: NotificationKind, on: boolean) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (on) next.add(kind);
      else next.delete(kind);
      return next;
    });

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (muteDate !== '' && muteDate <= today) {
      setMuteError('Choose a date after today, or clear it.');
      return;
    }
    setMuteError(null);
    try {
      await save.mutateAsync({
        pushKinds: nextPushKinds(saved?.push_kinds, visible, selected),
        mutedUntil: muteDate === '' ? null : shopLocalToUtcIso(muteDate, '00:00', timezone),
      });
      toast.success('Push settings saved');
    } catch (error) {
      toast.error('Couldn’t save your push settings', toAppError(error).message);
    }
  };

  const allOn = visible.every((k) => selected.has(k));

  return (
    <form noValidate onSubmit={(event) => void submit(event)} className="flex flex-col gap-5">
      <DevicesLine shopId={shopId} userId={userId} />
      <fieldset className="flex flex-col gap-2.5">
        <legend className="text-ink mb-2 text-sm font-medium">Send a push for</legend>
        <Checkbox
          checked={allOn}
          onChange={(event) =>
            setSelected(event.target.checked ? new Set(visible) : new Set<NotificationKind>())
          }
          label="Everything below"
        />
        <div className="grid gap-2.5 pl-6 sm:grid-cols-2">
          {visible.map((kind) => (
            <Checkbox
              key={kind}
              checked={selected.has(kind)}
              onChange={(event) => toggle(kind, event.target.checked)}
              label={KIND_LABELS[kind]}
            />
          ))}
        </div>
      </fieldset>
      <div className="flex flex-col gap-2">
        {mutedNow && saved?.muted_until && (
          <p className="text-warning-ink text-sm" role="status">
            Pushes are paused until {formatDateTime(saved.muted_until, timezone)}.
          </p>
        )}
        <div className="flex flex-wrap items-end gap-2">
          <FormField
            label="Pause pushes until"
            help="Pushes start again at midnight (shop time) on this date. Leave empty to keep them on."
            error={muteError}
            className="w-full max-w-xs"
          >
            <DateInput
              value={muteDate}
              min={tomorrow}
              onChange={(event) => {
                setMuteDate(event.target.value);
                setMuteError(null);
              }}
            />
          </FormField>
          {muteDate !== '' && (
            <Button variant="ghost" size="sm" onClick={() => setMuteDate('')} className="mb-6">
              Clear
            </Button>
          )}
        </div>
      </div>
      <div className="flex justify-end">
        <Button type="submit" loading={save.isPending}>
          Save push settings
        </Button>
      </div>
    </form>
  );
}

function DevicesLine({ shopId, userId }: { shopId: string; userId: string }) {
  const toast = useToast();
  const devices = usePushDeviceCount(userId);
  const test = useSendTestPush(shopId, userId);
  const count = devices.data ?? 0;

  const sendTest = async () => {
    try {
      const result = await test.mutateAsync();
      toast.success(
        result.sent === 1
          ? 'Test notification sent'
          : `Test notification sent to ${result.sent} devices`,
      );
    } catch (error) {
      toast.error('Couldn’t send a test notification', toAppError(error).message);
    }
  };

  return (
    <div className="bg-surface-2 rounded-control flex flex-wrap items-center gap-3 px-3 py-2.5">
      <Smartphone className="text-muted size-5 shrink-0" aria-hidden="true" />
      <p className="text-ink min-w-0 flex-1 text-sm">
        {devices.isPending
          ? 'Checking your devices…'
          : devices.isError
            ? 'Couldn’t check which devices have notifications on.'
            : count === 0
              ? 'No iPhone gets pushes yet. Sign in to the Detail CRM iPhone app and allow notifications.'
              : count === 1
                ? 'Notifications are on for 1 iPhone.'
                : `Notifications are on for ${count} iPhones.`}
      </p>
      <Button
        variant="secondary"
        size="sm"
        leadingIcon={<BellRing className="size-4" aria-hidden="true" />}
        disabled={count === 0}
        loading={test.isPending}
        onClick={() => void sendTest()}
      >
        Send a test
      </Button>
    </div>
  );
}
