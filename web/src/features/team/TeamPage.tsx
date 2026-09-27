import { MoreHorizontal, UserPlus, Users } from 'lucide-react';
import { useState } from 'react';
import {
  Avatar,
  Badge,
  Button,
  ConfirmDialog,
  DropdownMenu,
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  SectionCard,
  Table,
  useToast,
  type Column,
  type DropdownMenuEntry,
} from '@/components/ui';
import { formatPhone } from '@/lib/phone';
import { useAuth } from '@/features/auth/authContext';
import { ROLE_LABELS } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useCompensation, useTeam, useUpdateMember } from './api';
import { InviteDialog } from './components/InviteDialog';
import { InvitesCard } from './components/InvitesCard';
import {
  ChangeRoleDialog,
  CompensationDialog,
  MemberDetailsDialog,
} from './components/MemberDialogs';
import { TransferOwnershipCard } from './components/TransferOwnershipCard';
import {
  assignableRoles,
  canDeactivateMember,
  canEditMember,
  formatCompensation,
  sortMembers,
  targetOf,
  type TeamMember,
} from './model';

type Action =
  | { kind: 'role'; member: TeamMember }
  | { kind: 'pay'; member: TeamMember }
  | { kind: 'details'; member: TeamMember }
  | { kind: 'active'; member: TeamMember };

export default function TeamPage() {
  const { role, currency } = useShop();
  const { user } = useAuth();
  const toast = useToast();
  const canManage = useCan('team.manage');
  const canSeePay = useCan('compensation.view');
  const canPay = useCan('compensation.manage');
  const isOwner = role === 'owner';
  const team = useTeam();
  const compensation = useCompensation();
  const update = useUpdateMember();
  const [inviting, setInviting] = useState(false);
  const [action, setAction] = useState<Action | null>(null);
  const [now] = useState(() => new Date());

  const members = sortMembers(team.data ?? []);

  const menuFor = (member: TeamMember): DropdownMenuEntry[] => {
    const target = targetOf(member, user?.id);
    const entries: DropdownMenuEntry[] = [];
    if (assignableRoles(role, target).length > 0 && member.active)
      entries.push({
        key: 'role',
        label: 'Change role…',
        onSelect: () => setAction({ kind: 'role', member }),
      });
    if (canEditMember(role, target))
      entries.push({
        key: 'details',
        label: 'Edit name & colour…',
        onSelect: () => setAction({ kind: 'details', member }),
      });
    // Admins never modify the owner (SPEC §3), pay included.
    if (canPay && (role === 'owner' || member.role !== 'owner'))
      entries.push({
        key: 'pay',
        label: 'Edit pay…',
        onSelect: () => setAction({ kind: 'pay', member }),
      });
    if (canDeactivateMember(role, target))
      entries.push(
        { key: 'sep', separator: true },
        {
          key: 'active',
          label: member.active ? 'Deactivate' : 'Reactivate',
          tone: member.active ? 'danger' : 'default',
          onSelect: () => setAction({ kind: 'active', member }),
        },
      );
    return entries;
  };

  const columns: Column<TeamMember>[] = [
    {
      key: 'name',
      header: 'Member',
      primary: true,
      cell: (m) => (
        <span className="flex items-center gap-3">
          <Avatar name={m.display_name} color={m.calendar_color} size="sm" />
          <span className="min-w-0">
            <span className="text-ink block truncate font-medium">
              {m.display_name}
              {m.user_id === user?.id && <span className="text-muted font-normal"> (you)</span>}
            </span>
            {(m.email || m.phone) && (
              <span className="text-muted block truncate text-xs">
                {[m.email, formatPhone(m.phone)].filter(Boolean).join(' · ')}
              </span>
            )}
          </span>
        </span>
      ),
    },
    {
      key: 'role',
      header: 'Role',
      cell: (m) => (
        <Badge tone={m.role === 'owner' ? 'info' : 'neutral'}>{ROLE_LABELS[m.role]}</Badge>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      cell: (m) =>
        m.active ? (
          <Badge tone="success" dot>
            Active
          </Badge>
        ) : (
          <Badge tone="neutral" dot>
            Inactive
          </Badge>
        ),
    },
    ...(canSeePay
      ? [
          {
            key: 'pay',
            header: 'Pay',
            cell: (m: TeamMember) =>
              compensation.isPending
                ? '…'
                : compensation.error
                  ? '—'
                  : formatCompensation(compensation.data?.get(m.member_id), currency),
          } satisfies Column<TeamMember>,
        ]
      : []),
    ...(canManage
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (m: TeamMember) => {
              const items = menuFor(m);
              if (items.length === 0) return null;
              return (
                <DropdownMenu
                  items={items}
                  trigger={(props) => (
                    <button
                      type="button"
                      {...props}
                      aria-label={`Actions for ${m.display_name}`}
                      className="text-muted hover:bg-surface-2 hover:text-ink rounded-control inline-flex size-8 items-center justify-center"
                    >
                      <MoreHorizontal className="size-4" aria-hidden="true" />
                    </button>
                  )}
                />
              );
            },
          } satisfies Column<TeamMember>,
        ]
      : []),
  ];

  let membersBody;
  if (team.isPending) membersBody = <LoadingState label="Loading team…" variant="rows" />;
  else if (team.error)
    membersBody = (
      <ErrorState
        error={team.error}
        title="Couldn’t load the team"
        onRetry={() => void team.refetch()}
        retrying={team.isRefetching}
      />
    );
  else if (members.length === 0)
    membersBody = (
      <EmptyState icon={<Users aria-hidden="true" />} title="No team members yet" compact />
    );
  else
    membersBody = (
      <Table
        caption="Team members"
        columns={columns}
        rows={members}
        getRowId={(m) => m.member_id}
      />
    );

  const toggling = action?.kind === 'active' ? action.member : null;

  return (
    <>
      <PageHeader
        title="Team"
        description={
          canManage ? 'Invites, roles and pay rates.' : 'Everyone on the team and their roles.'
        }
        actions={
          canManage ? (
            <Button leadingIcon={<UserPlus />} onClick={() => setInviting(true)}>
              Invite member
            </Button>
          ) : undefined
        }
      />
      <div className="flex flex-col gap-5">
        <SectionCard title="Members" flush>
          {membersBody}
        </SectionCard>
        {canManage && <InvitesCard onInvite={() => setInviting(true)} now={now} />}
        {isOwner && team.data && <TransferOwnershipCard members={team.data} />}
      </div>

      {canManage && <InviteDialog open={inviting} onClose={() => setInviting(false)} />}
      {action?.kind === 'role' && (
        <ChangeRoleDialog
          member={action.member}
          roles={assignableRoles(role, targetOf(action.member, user?.id))}
          onClose={() => setAction(null)}
        />
      )}
      {action?.kind === 'pay' && (
        <CompensationDialog
          member={action.member}
          current={compensation.data?.get(action.member.member_id)}
          onClose={() => setAction(null)}
        />
      )}
      {action?.kind === 'details' && (
        <MemberDetailsDialog member={action.member} onClose={() => setAction(null)} />
      )}
      <ConfirmDialog
        open={toggling !== null}
        onClose={() => setAction(null)}
        tone={toggling?.active ? 'danger' : 'primary'}
        loading={update.isPending}
        title={
          toggling?.active
            ? `Deactivate ${toggling.display_name}?`
            : `Reactivate ${toggling?.display_name ?? ''}?`
        }
        description={
          toggling?.active
            ? 'They lose access to this shop right away. Their jobs, time entries and history stay.'
            : 'They regain access with their current role.'
        }
        confirmLabel={toggling?.active ? 'Deactivate' : 'Reactivate'}
        onConfirm={async () => {
          if (!toggling) return;
          try {
            await update.mutateAsync({
              memberId: toggling.member_id,
              patch: { active: !toggling.active },
            });
            toast.success(toggling.active ? 'Member deactivated' : 'Member reactivated');
          } catch (error) {
            toast.error(error);
          } finally {
            setAction(null);
          }
        }}
      />
    </>
  );
}
