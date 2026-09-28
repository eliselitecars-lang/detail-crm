import { Avatar, Checkbox, ErrorState, LoadingState, SectionCard, useToast } from '@/components/ui';
import { ROLE_LABELS } from '@/features/shop/permissions';
import { useCan } from '@/features/shop/useCan';
import { useAssignments, useSetAssigned, useTeam, type JobDetail } from '../../api';
import { SoldByField } from './PeopleCards';

export function AssignmentsCard({ job }: { job: JobDetail }) {
  const jobId = job.id;
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const team = useTeam();
  const assignments = useAssignments(jobId);
  const setAssigned = useSetAssigned(jobId);

  const assigned = new Set((assignments.data ?? []).map((a) => a.member_id));
  const members = team.data ?? [];

  const body = () => {
    if (assignments.isPending || team.isPending) return <LoadingState label="Loading team…" />;
    if (assignments.isError || team.isError) {
      return (
        <ErrorState
          compact
          error={assignments.error ?? team.error}
          onRetry={() => {
            void assignments.refetch();
            void team.refetch();
          }}
        />
      );
    }
    if (canManage) {
      const choices = members.filter((m) => m.active || assigned.has(m.memberId));
      if (choices.length === 0) return <p className="text-muted text-sm">No team members yet.</p>;
      return (
        <fieldset className="flex flex-col gap-2.5">
          <legend className="sr-only">Assigned team members</legend>
          {choices.map((m) => (
            <Checkbox
              key={m.memberId}
              label={m.name}
              description={ROLE_LABELS[m.role]}
              checked={assigned.has(m.memberId)}
              disabled={setAssigned.isPending}
              onChange={(e) => {
                const next = e.target.checked;
                setAssigned
                  .mutateAsync({ memberId: m.memberId, assigned: next })
                  .catch((error: unknown) => toast.error(error));
              }}
            />
          ))}
        </fieldset>
      );
    }
    const list = members.filter((m) => assigned.has(m.memberId));
    if (list.length === 0) return <p className="text-muted text-sm">Nobody is assigned yet.</p>;
    return (
      <ul className="flex flex-col gap-2">
        {list.map((m) => (
          <li key={m.memberId} className="flex items-center gap-2 text-sm">
            <Avatar name={m.name} color={m.color} size="xs" />
            {m.name}
          </li>
        ))}
      </ul>
    );
  };

  return (
    <SectionCard title="Team" level={3}>
      <div className="flex flex-col gap-4">
        {body()}
        {team.isSuccess && (
          <div className="border-line border-t pt-3">
            <SoldByField job={job} team={members} />
          </div>
        )}
      </div>
    </SectionCard>
  );
}
