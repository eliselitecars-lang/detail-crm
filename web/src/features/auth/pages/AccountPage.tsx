import { ArrowLeft, FileText, LogOut, Shield, Store, Trash2 } from 'lucide-react';
import { useId, useRef, useState, type FormEvent } from 'react';
import { Link, useLocation } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Button,
  ConfirmDialog,
  Dialog,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  SectionCard,
  useToast,
} from '@/components/ui';
import { ROLE_LABELS } from '@/features/shop/permissions';
import type { ShopMembership } from '@/features/shop/types';
import { PRIVACY_PATH, TERMS_PATH } from '@/features/legal/paths';
import { errorMessage } from '@/lib/errors';
import { storageKeys, writeLocal } from '@/lib/storage';
import {
  ownedShopsOf,
  useDeleteAccount,
  useLeaveShop,
  useMyMemberships,
  type OwnedShop,
} from '../accountApi';
import { useAuth } from '../authContext';
import { ACCOUNT_DELETED_LOGIN, reloadTo } from '../leave';

/** What the person types to confirm (case-insensitive). */
export const DELETE_CONFIRMATION = 'DELETE';

/** Where "Back" goes: the page that linked here (UserMenu / portal pass `from`). */
function backTarget(state: unknown): string | null {
  const from = (state as { from?: unknown } | null)?.from;
  return typeof from === 'string' && from.startsWith('/') && !from.startsWith('//') ? from : null;
}

/**
 * /account — the signed-in user's own account, for every role (staff and
 * portal clients). Deleting the account is required by App Store guideline
 * 5.1.1(v); the server refuses while the user still owns a shop.
 */
export default function AccountPage() {
  const { user } = useAuth();
  const location = useLocation();
  const back = backTarget(location.state);

  return (
    <PublicLayout shop={{ name: 'Your account' }} accountLink={false}>
      <div className="flex flex-col gap-4 sm:gap-5">
        <div className="flex flex-col gap-2">
          {back && (
            <Link
              to={back}
              className="text-primary-ink inline-flex w-fit items-center gap-1 text-sm hover:underline"
            >
              <ArrowLeft className="size-4" aria-hidden="true" />
              Back
            </Link>
          )}
          <h1 className="text-ink text-xl font-semibold sm:text-2xl">Your account</h1>
          {user?.email && <p className="text-muted text-sm break-all">Signed in as {user.email}</p>}
        </div>
        <YourShopsCard />
        <DeleteAccountCard />
        <LegalCard />
      </div>
    </PublicLayout>
  );
}

/**
 * The shop teams the user belongs to, each with "Leave" (leave_shop) for
 * every role but owner. Hidden for someone on no team (a portal client).
 */
function YourShopsCard() {
  const { user } = useAuth();
  const userId = user?.id ?? '';
  const memberships = useMyMemberships(userId);
  const [leaving, setLeaving] = useState<ShopMembership | null>(null);

  if (memberships.isPending) {
    return (
      <SectionCard title="Your shops">
        <LoadingState variant="rows" rows={2} label="Loading your shops…" />
      </SectionCard>
    );
  }
  if (memberships.isError) {
    return (
      <SectionCard title="Your shops">
        <ErrorState
          compact
          error={memberships.error}
          onRetry={() => void memberships.refetch()}
          retrying={memberships.isRefetching}
        />
      </SectionCard>
    );
  }
  const rows = [...memberships.data].sort((a, b) => a.shop.name.localeCompare(b.shop.name));
  if (rows.length === 0) return null;

  return (
    <SectionCard
      title="Your shops"
      description="The shop teams you belong to. Leaving one removes your access to it; your other shops are not affected."
    >
      <ul className="divide-line flex flex-col divide-y" aria-label="Your shops">
        {rows.map((m) => (
          <li
            key={m.memberId}
            className="flex flex-wrap items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
          >
            <span className="flex min-w-0 items-center gap-2">
              <Store className="text-muted size-4 shrink-0" aria-hidden="true" />
              <span className="min-w-0">
                <span className="text-ink block truncate text-sm font-medium">{m.shop.name}</span>
                <span className="text-muted block text-sm">{ROLE_LABELS[m.role]}</span>
              </span>
            </span>
            {m.role === 'owner' ? (
              <span className="text-muted text-sm">Transfer ownership to leave</span>
            ) : (
              <Button
                variant="secondary"
                size="sm"
                leadingIcon={<LogOut className="size-4" aria-hidden="true" />}
                aria-label={`Leave ${m.shop.name}`}
                onClick={() => setLeaving(m)}
              >
                Leave…
              </Button>
            )}
          </li>
        ))}
      </ul>
      {leaving && (
        <LeaveShopDialog userId={userId} membership={leaving} onClose={() => setLeaving(null)} />
      )}
    </SectionCard>
  );
}

function LeaveShopDialog({
  userId,
  membership,
  onClose,
}: {
  userId: string;
  membership: ShopMembership;
  onClose: () => void;
}) {
  const toast = useToast();
  const leave = useLeaveShop(userId);
  const name = membership.shop.name;

  const confirm = async () => {
    try {
      await leave.mutateAsync(membership.shopId);
      toast.success(`You left ${name}`);
      onClose();
    } catch {
      // shown in the dialog
    }
  };

  return (
    <ConfirmDialog
      open
      onClose={onClose}
      onConfirm={() => void confirm()}
      title={`Leave ${name}?`}
      description="You lose access to its schedule, jobs and customers right away, and you’re clocked out of any open time entry there. To come back, an admin has to invite you again."
      confirmLabel="Leave shop"
      tone="danger"
      loading={leave.isPending}
    >
      {leave.isError && (
        <p
          role="alert"
          className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
        >
          {errorMessage(leave.error)}
        </p>
      )}
    </ConfirmDialog>
  );
}

/** The operator's Privacy Policy and Terms of Service (every role). */
function LegalCard() {
  const link =
    'text-primary-ink inline-flex w-fit items-center gap-2 text-sm font-medium hover:underline';
  return (
    <SectionCard
      title="Privacy and terms"
      description="How your information is handled and the terms for using the service."
    >
      <ul className="flex flex-col gap-2.5">
        <li>
          <Link to={PRIVACY_PATH} className={link}>
            <Shield className="size-4" aria-hidden="true" />
            Privacy Policy
          </Link>
        </li>
        <li>
          <Link to={TERMS_PATH} className={link}>
            <FileText className="size-4" aria-hidden="true" />
            Terms of Service
          </Link>
        </li>
      </ul>
    </SectionCard>
  );
}

function DeleteAccountCard() {
  const [open, setOpen] = useState(false);
  return (
    <SectionCard
      title="Delete account"
      description="Permanently deletes your sign-in and profile. This cannot be undone."
    >
      <div className="flex flex-col gap-4 text-sm">
        <ul className="text-muted flex list-disc flex-col gap-1.5 pl-5">
          <li>You are signed out everywhere and can no longer sign in with this email.</li>
          <li>You are removed from every shop team you belong to.</li>
          <li>
            Records a shop keeps for its business (appointments, invoices, payments) stay with that
            shop; your client portal link to them is removed.
          </li>
          <li>If you own a shop, transfer its ownership or delete the shop first.</li>
        </ul>
        <div>
          <Button variant="danger" onClick={() => setOpen(true)}>
            <Trash2 className="size-4" aria-hidden="true" />
            Delete account…
          </Button>
        </div>
      </div>
      {open && <DeleteAccountDialog onClose={() => setOpen(false)} />}
    </SectionCard>
  );
}

function DeleteAccountDialog({ onClose }: { onClose: () => void }) {
  const { signOut } = useAuth();
  const remove = useDeleteAccount();
  const [typed, setTyped] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const formId = useId();
  const matches = typed.trim().toUpperCase() === DELETE_CONFIRMATION;
  const blockers = remove.isError ? ownedShopsOf(remove.error) : null;

  const close = () => {
    if (remove.isPending) return;
    onClose();
  };

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault();
    if (!matches || remove.isPending) return;
    try {
      await remove.mutateAsync();
    } catch {
      return; // shown in the dialog
    }
    // The account is gone: clear the local session even if the server no
    // longer accepts the token, then start over on the sign-in page with a
    // full load (no cache of the deleted account survives in memory).
    await signOut().catch(() => undefined);
    reloadTo(ACCOUNT_DELETED_LOGIN);
  };

  return (
    <Dialog
      open
      onClose={close}
      role="alertdialog"
      size="sm"
      title="Delete your account?"
      description="Your sign-in and profile are permanently deleted."
      dismissible={!remove.isPending}
      initialFocus={inputRef}
      footer={
        <>
          <Button variant="secondary" onClick={close} disabled={remove.isPending}>
            Cancel
          </Button>
          <Button
            type="submit"
            form={formId}
            variant="danger"
            disabled={!matches}
            loading={remove.isPending}
          >
            Delete account permanently
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="flex flex-col gap-3"
      >
        <FormField label={`Type ${DELETE_CONFIRMATION} to confirm`}>
          <Input
            ref={inputRef}
            value={typed}
            autoComplete="off"
            spellCheck={false}
            onChange={(e) => setTyped(e.target.value)}
          />
        </FormField>
        {blockers ? (
          <OwnsShops shops={blockers} />
        ) : (
          remove.isError && (
            <p
              role="alert"
              className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
            >
              {errorMessage(remove.error)}
            </p>
          )
        )}
      </form>
    </Dialog>
  );
}

/** The 409 owns_shops answer: each shop with the two ways out. */
function OwnsShops({ shops }: { shops: OwnedShop[] }) {
  const { user } = useAuth();
  // The app opens on the last-used shop: pick this one before going there.
  const pick = (shopId: string) => {
    if (user?.id) writeLocal(storageKeys.lastShop(user.id), shopId);
  };
  return (
    <div role="alert" className="bg-warning-soft text-warning-ink rounded-control px-3 py-2.5">
      <p className="text-sm font-medium">
        You own {shops.length === 1 ? 'a shop' : 'these shops'}. Transfer ownership or delete{' '}
        {shops.length === 1 ? 'it' : 'them'} first.
      </p>
      <ul className="mt-2 flex flex-col gap-2" aria-label="Shops you own">
        {shops.map((shop) => (
          <li key={shop.shop_id} className="flex flex-col gap-1">
            <span className="text-ink flex items-center gap-1.5 text-sm font-medium">
              <Store className="size-4 shrink-0" aria-hidden="true" />
              {shop.name}
            </span>
            <span className="flex flex-wrap gap-x-4 gap-y-1 pl-5 text-sm">
              <Link
                to="/app/team"
                onClick={() => pick(shop.shop_id)}
                className="text-primary-ink font-medium hover:underline"
                aria-label={`Transfer ownership of ${shop.name}`}
              >
                Transfer ownership
              </Link>
              <Link
                to="/app/settings/delete-shop"
                onClick={() => pick(shop.shop_id)}
                className="text-primary-ink font-medium hover:underline"
                aria-label={`Delete ${shop.name}`}
              >
                Delete shop
              </Link>
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
