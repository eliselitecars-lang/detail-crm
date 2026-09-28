import { Pencil } from 'lucide-react';
import { useState } from 'react';
import { Button, ErrorState, LoadingState, SectionCard, useToast } from '@/components/ui';
import { CustomFieldInputs, CustomFieldValues } from '@/components/customFields';
import { fromDraft, toDraft, type CustomFieldDraft } from '@/lib/customFields';
import { toFieldDef, useCustomFields } from '@/features/settings/data/customFields';
import { useCan } from '@/features/shop/useCan';
import { useUpdateJob, type JobDetail } from '../../api';

/**
 * The shop's job fields (P-9): booking answers and anything the team
 * records on the job (jobs.custom_data, validated by the server). Managers
 * edit; technicians read.
 */
export function JobCustomDataCard({ job }: { job: JobDetail }) {
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const fields = useCustomFields('job');
  const update = useUpdateJob(job.id);
  const [draft, setDraft] = useState<CustomFieldDraft | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});

  const defs = (fields.data ?? []).map(toFieldDef);
  const liveFields = defs.filter((f) => !f.archived_at);
  const hasData = Object.keys(job.custom_data).length > 0;
  if (fields.isSuccess && liveFields.length === 0 && !hasData) return null;

  const save = async () => {
    if (!draft) return;
    const result = fromDraft(defs, draft, { previous: job.custom_data });
    setErrors(result.errors);
    if (!result.valid) return;
    try {
      await update.mutateAsync({ custom_data: result.data });
      toast.success('Details saved');
      setDraft(null);
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard
      title="Job details"
      level={3}
      actions={
        canManage && draft === null && fields.isSuccess && liveFields.length > 0 ? (
          <Button
            size="sm"
            variant="ghost"
            leadingIcon={<Pencil className="size-4" aria-hidden="true" />}
            onClick={() => {
              setErrors({});
              setDraft(toDraft(defs, job.custom_data));
            }}
          >
            Edit
          </Button>
        ) : undefined
      }
    >
      {fields.isPending ? (
        <LoadingState label="Loading details…" />
      ) : fields.isError ? (
        <ErrorState compact error={fields.error} onRetry={() => void fields.refetch()} />
      ) : draft !== null ? (
        <form
          className="flex flex-col gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <CustomFieldInputs
            fields={defs}
            value={draft}
            onChange={setDraft}
            errors={errors}
            disabled={update.isPending}
          />
          <div className="flex justify-end gap-2">
            <Button
              variant="secondary"
              disabled={update.isPending}
              onClick={() => {
                setDraft(null);
                setErrors({});
              }}
            >
              Cancel
            </Button>
            <Button type="submit" loading={update.isPending}>
              Save details
            </Button>
          </div>
        </form>
      ) : (
        <CustomFieldValues fields={defs} data={job.custom_data} emptyText="Nothing recorded yet." />
      )}
    </SectionCard>
  );
}
