import { useState } from 'react';
import { Link } from 'react-router';
import { Button, ErrorState, LoadingState, SectionCard, useToast } from '@/components/ui';
import { CustomFieldInputs, CustomFieldValues } from '@/components/customFields';
import {
  fromDraft,
  readCustomData,
  toDraft,
  type CustomData,
  type CustomFieldDef,
  type CustomFieldDraft,
} from '@/lib/customFields';
import { useCan } from '@/features/shop/useCan';
import type { CustomerRow } from '../model';
import { useCustomerFields, useUpdateCustomerCustomData } from '../parityApi';

/**
 * The shop's customer fields (Settings → Custom fields) for this customer:
 * read-only for everyone who can see the customer, editable by managers+.
 * Values are validated like the server does, which re-checks them.
 */
export function CustomDataCard({ customer }: { customer: CustomerRow }) {
  const fields = useCustomerFields();
  const canEdit = useCan('customers.manage') && customer.archived_at === null;
  const canDefine = useCan('settings.manage');
  const data = readCustomData(customer.custom_data);

  if (fields.isPending) {
    return (
      <SectionCard title="More details" level={2} className="lg:col-span-2">
        <LoadingState variant="rows" rows={2} label="Loading fields…" />
      </SectionCard>
    );
  }
  if (fields.isError) {
    return (
      <SectionCard title="More details" level={2} className="lg:col-span-2">
        <ErrorState compact error={fields.error} onRetry={() => void fields.refetch()} />
      </SectionCard>
    );
  }
  const live = fields.data.filter((f) => !f.archived_at);
  if (fields.data.length === 0 || (live.length === 0 && Object.keys(data).length === 0)) {
    if (!canDefine) return null;
    return (
      <SectionCard title="More details" level={2} className="lg:col-span-2">
        <p className="text-muted text-sm">
          Track extra details on every customer (preferred contact time, gate code, fleet number…).{' '}
          <Link to="/app/settings/custom-fields" className="text-primary-ink hover:underline">
            Add custom fields
          </Link>
        </p>
      </SectionCard>
    );
  }
  return (
    <CustomDataEditor
      key={customer.updated_at}
      customerId={customer.id}
      fields={fields.data}
      data={data}
      canEdit={canEdit}
    />
  );
}

function CustomDataEditor({
  customerId,
  fields,
  data,
  canEdit,
}: {
  customerId: string;
  fields: readonly CustomFieldDef[];
  data: CustomData;
  canEdit: boolean;
}) {
  const toast = useToast();
  const update = useUpdateCustomerCustomData(customerId);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<CustomFieldDraft>(() => toDraft(fields, data));
  const [errors, setErrors] = useState<Record<string, string>>({});

  const save = async () => {
    const result = fromDraft(fields, draft, { previous: data });
    setErrors(result.errors);
    if (!result.valid) return;
    try {
      await update.mutateAsync(result.data);
      toast.success('Details saved');
      setEditing(false);
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard
      title="More details"
      level={2}
      className="lg:col-span-2"
      actions={
        canEdit && !editing ? (
          <Button size="sm" variant="secondary" onClick={() => setEditing(true)}>
            Edit
          </Button>
        ) : undefined
      }
      footer={
        editing ? (
          <div className="flex justify-end gap-2">
            <Button
              variant="ghost"
              size="sm"
              disabled={update.isPending}
              onClick={() => {
                setDraft(toDraft(fields, data));
                setErrors({});
                setEditing(false);
              }}
            >
              Cancel
            </Button>
            <Button size="sm" loading={update.isPending} onClick={() => void save()}>
              Save details
            </Button>
          </div>
        ) : undefined
      }
    >
      {editing ? (
        <CustomFieldInputs
          fields={fields}
          value={draft}
          onChange={setDraft}
          errors={errors}
          columns={2}
        />
      ) : (
        <CustomFieldValues fields={fields} data={data} layout="grid" showEmpty />
      )}
    </SectionCard>
  );
}
