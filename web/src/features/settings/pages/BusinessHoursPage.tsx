import { useState } from 'react';
import { SectionCard, useToast } from '@/components/ui';
import {
  rowsToWeek,
  validateWeek,
  weekToRows,
  type BusinessHoursRow,
  type DayHours,
} from '@/features/shop/businessHours';
import { BusinessHoursEditor } from '@/features/shop/components/BusinessHoursEditor';
import { useBusinessHours, useSaveBusinessHours } from '../api';
import { FormActions } from '../components/FormActions';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { useSettingsAccess } from '../useSettingsAccess';

export default function BusinessHoursPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const query = useBusinessHours();
  return (
    <SettingsSectionLayout section="hours" readOnly={readOnly}>
      <QueryView query={query} label="business hours">
        {(rows) => <HoursForm key={JSON.stringify(rows)} rows={rows} canEdit={canEdit} />}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function sameWeek(a: readonly DayHours[], b: readonly DayHours[]): boolean {
  return JSON.stringify(weekToRows(a)) === JSON.stringify(weekToRows(b));
}

function HoursForm({ rows, canEdit }: { rows: BusinessHoursRow[]; canEdit: boolean }) {
  const toast = useToast();
  const save = useSaveBusinessHours();
  const [initial] = useState(() => rowsToWeek(rows));
  const [week, setWeek] = useState<DayHours[]>(initial);
  const [showErrors, setShowErrors] = useState(false);
  const errors = showErrors ? validateWeek(week) : {};
  const dirty = !sameWeek(week, initial);

  const onSubmit = async () => {
    const problems = validateWeek(week);
    if (Object.keys(problems).length > 0) {
      setShowErrors(true);
      return;
    }
    try {
      await save.mutateAsync({ rows: weekToRows(week) });
      toast.success('Business hours saved');
    } catch (error) {
      toast.error(error);
    }
  };

  const openDays = week.filter((d) => d.open).length;

  return (
    <form
      noValidate
      onSubmit={(event) => {
        event.preventDefault();
        void onSubmit();
      }}
      className="flex flex-col gap-4"
    >
      <SectionCard
        title="Weekly hours"
        description={
          openDays === 0
            ? 'You are closed every day, so the booking page offers no times.'
            : 'Times are in your shop’s time zone. Add a second range for a lunch break.'
        }
      >
        <BusinessHoursEditor
          value={week}
          onChange={(next) => {
            setWeek(next);
            if (showErrors && Object.keys(validateWeek(next)).length === 0) setShowErrors(false);
          }}
          errors={errors}
          disabled={!canEdit}
        />
      </SectionCard>
      {canEdit && (
        <FormActions
          dirty={dirty}
          saving={save.isPending}
          onDiscard={() => {
            setWeek(initial);
            setShowErrors(false);
          }}
        />
      )}
    </form>
  );
}
