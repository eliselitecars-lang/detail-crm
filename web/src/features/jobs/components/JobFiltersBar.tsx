import { X } from 'lucide-react';
import { Button, DateInput, FormField, SearchInput, Select, statusLabel } from '@/components/ui';
import { cn } from '@/lib/cn';
import type { TeamMember } from '../api';
import { hasActiveFilters, JOB_STATUSES, type JobFilters, type JobStatus } from '../model';

export interface JobFiltersBarProps {
  filters: JobFilters;
  onChange: (next: Partial<JobFilters>) => void;
  onClear: () => void;
  /** Managers+ filter by assignee; technicians only ever see their own jobs. */
  team: TeamMember[] | null;
}

export function JobFiltersBar({ filters, onChange, onClear, team }: JobFiltersBarProps) {
  const toggleStatus = (status: JobStatus) => {
    const next = filters.statuses.includes(status)
      ? filters.statuses.filter((s) => s !== status)
      : [...filters.statuses, status];
    onChange({ statuses: next });
  };

  return (
    <div className="flex flex-col gap-3 p-4">
      <SearchInput
        label="Search jobs"
        placeholder="Search by job number, customer or vehicle…"
        value={filters.search}
        onChange={(search) => onChange({ search })}
      />
      <fieldset>
        <legend className="text-muted mb-1.5 text-xs font-semibold tracking-wide uppercase">
          Status
        </legend>
        <div className="flex flex-wrap gap-1.5">
          {JOB_STATUSES.map((status) => {
            const active = filters.statuses.includes(status);
            return (
              <button
                key={status}
                type="button"
                aria-pressed={active}
                onClick={() => toggleStatus(status)}
                className={cn(
                  'rounded-full border px-3 py-1 text-xs font-medium transition-colors',
                  active
                    ? 'border-primary bg-primary-soft text-primary-ink'
                    : 'border-line-strong bg-surface text-muted hover:bg-surface-2 hover:text-ink',
                )}
              >
                {statusLabel('job', status)}
              </button>
            );
          })}
        </div>
      </fieldset>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <FormField label="From">
          <DateInput
            value={filters.from ?? ''}
            onChange={(e) => onChange({ from: e.target.value || null })}
          />
        </FormField>
        <FormField label="To">
          <DateInput
            value={filters.to ?? ''}
            min={filters.from ?? undefined}
            onChange={(e) => onChange({ to: e.target.value || null })}
          />
        </FormField>
        {team && (
          <FormField label="Assigned to">
            <Select
              value={filters.assigneeId ?? ''}
              onChange={(e) => onChange({ assigneeId: e.target.value || null })}
              options={[
                { value: '', label: 'Anyone' },
                ...team.map((m) => ({ value: m.memberId, label: m.name })),
              ]}
            />
          </FormField>
        )}
        {hasActiveFilters(filters) && (
          <div className="flex items-end">
            <Button
              variant="ghost"
              leadingIcon={<X className="size-4" aria-hidden="true" />}
              onClick={onClear}
            >
              Clear filters
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
