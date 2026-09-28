import { AlertTriangle } from 'lucide-react';
import { useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router';
import {
  Button,
  buttonClasses,
  Checkbox,
  DateInput,
  FormField,
  Input,
  MoneyInput,
  PageHeader,
  RadioGroup,
  SectionCard,
  Select,
  Textarea,
  TimeInput,
  useToast,
} from '@/components/ui';
import { isLocalDate, shopToday, utcToShopLocal } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { BillingErrorLink } from '@/features/billing/BillingErrorLink';
import { useShop } from '@/features/shop/shopContext';
import {
  useCatalog,
  usePricing,
  useResources,
  useTeam,
  useVehicleCategories,
  type LineDraft,
} from './api';
import { RepeatFields, SeriesPreview } from './components/RepeatFields';
import { CustomerSection } from './components/new/CustomerSection';
import { ServicesSection } from './components/new/ServicesSection';
import { VehicleSection } from './components/new/VehicleSection';
import {
  addMinutesLocal,
  defaultSchedule,
  formatDuration,
  scheduleToUtc,
  sumDurations,
  type LocalDateTime,
  type LocationType,
} from './model';
import {
  CreateJobError,
  EMPTY_PROGRESS,
  useCreateJob,
  useCustomer,
  type CreateJobInput,
  type CreateJobProgress,
  type CustomerOption,
} from './newJobApi';
import {
  defaultRepeatDraft,
  localWeekday,
  repeatRuleFields,
  SERIES_LIMITS,
  spanMinutes,
  type RepeatDraft,
} from './series';
import { useCreateSeries } from './seriesApi';

function isoParam(params: URLSearchParams, key: string): string | null {
  const value = params.get(key);
  return value && !Number.isNaN(Date.parse(value)) ? value : null;
}

export default function NewJobPage() {
  const { timezone, shop, memberId } = useShop();
  const toast = useToast();
  const navigate = useNavigate();
  const [params] = useSearchParams();

  // --- prefill from ?customerId&start&end ----------------------------------
  const paramCustomerId = params.get('customerId');
  const paramStart = isoParam(params, 'start');
  const paramEnd = isoParam(params, 'end');
  const paramCustomer = useCustomer(paramCustomerId);
  const [picked, setPicked] = useState<CustomerOption | null | undefined>(undefined);
  const customer = picked === undefined ? (paramCustomer.data ?? null) : picked;

  const [initialSchedule] = useState(() => {
    if (paramStart) {
      const start = utcToShopLocal(paramStart, timezone);
      const end =
        paramEnd && Date.parse(paramEnd) > Date.parse(paramStart)
          ? utcToShopLocal(paramEnd, timezone)
          : null;
      return { start, end };
    }
    const d = defaultSchedule(shopToday(timezone));
    return { start: d.start, end: null };
  });

  const [vehicleId, setVehicleId] = useState<string | null>(null);
  /** The picked vehicle's own size (repeating jobs are priced from it). */
  const [vehicleSize, setVehicleSize] = useState<string | null>(null);
  const [categoryId, setCategoryId] = useState('');
  const [selected, setSelected] = useState<string[]>([]);
  const [applyMemberDiscount, setApplyMemberDiscount] = useState(true);
  const [mode, setMode] = useState<'now' | 'later'>('now');
  const [start, setStart] = useState<LocalDateTime>(initialSchedule.start);
  const [repeat, setRepeat] = useState(false);
  const [repeatDraft, setRepeatDraft] = useState<RepeatDraft>(() =>
    defaultRepeatDraft(initialSchedule.start.date),
  );
  const [soldBy, setSoldBy] = useState(memberId);
  const [endOverride, setEndOverride] = useState<LocalDateTime | null>(initialSchedule.end);
  const [location, setLocation] = useState<LocationType>(
    shop.business_type === 'mobile' ? 'mobile' : 'shop',
  );
  const [address, setAddress] = useState({
    line1: '',
    line2: '',
    city: '',
    region: '',
    postal: '',
  });
  // ?resourceId= comes from a slot picked in the calendar's bay / van view.
  const [resourceId, setResourceId] = useState(params.get('resourceId') ?? '');
  const [assignees, setAssignees] = useState<string[]>([]);
  const [notes, setNotes] = useState('');
  const [internalNotes, setInternalNotes] = useState('');
  const [deposit, setDeposit] = useState<number | null>(null);
  const [progress, setProgress] = useState<CreateJobProgress>(EMPTY_PROGRESS);
  // Once the job row exists, retries replay exactly the input it was created
  // from (the form is locked): later stages can't drift from the saved job.
  const [committed, setCommitted] = useState<CreateJobInput | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  /** The error behind formError (the owner's billing link on a subscription refusal). */
  const [formErrorCause, setFormErrorCause] = useState<unknown>(null);

  const catalog = useCatalog();
  const categories = useVehicleCategories();
  const resources = useResources();
  const team = useTeam();
  const create = useCreateJob();
  const createSeries = useCreateSeries();
  const repeating = repeat && mode === 'now';

  // A shop without vehicle sizes prices every service at its base price.
  const noSizes = categories.isSuccess && categories.data.length === 0;
  const pricing = usePricing(
    customer && (categoryId || noSizes) && selected.length > 0
      ? {
          customerId: customer.id,
          vehicleCategoryId: categoryId || null,
          vehicleId,
          serviceIds: selected,
        }
      : null,
  );

  const catalogMinutes = sumDurations(
    (catalog.data?.services ?? [])
      .filter((s) => selected.includes(s.id))
      .map((s) => s.duration_minutes),
  );
  const minutes = pricing.data?.duration_minutes ?? catalogMinutes;
  const autoEnd = addMinutesLocal(start, minutes > 0 ? minutes : 60, timezone);
  const end = endOverride ?? autoEnd ?? start;

  /** A new start date moves the default weekday of a weekly repeat with it. */
  const changeStartDate = (date: string) => {
    const previous = start.date;
    setStart((s) => ({ ...s, date }));
    if (!isLocalDate(date) || !isLocalDate(previous)) return;
    setRepeatDraft((d) =>
      d.weekdays.length === 1 && d.weekdays[0] === localWeekday(previous)
        ? { ...d, weekdays: [localWeekday(date)] }
        : d,
    );
  };

  const changeCustomer = (next: CustomerOption | null) => {
    setPicked(next);
    setVehicleId(null);
    setVehicleSize(null);
    if (next && location === 'mobile' && !address.line1) {
      setAddress({
        line1: next.address_line1 ?? '',
        line2: next.address_line2 ?? '',
        city: next.city ?? '',
        region: next.region ?? '',
        postal: next.postal_code ?? '',
      });
    }
  };

  const activeTeam = (team.data ?? []).filter((m) => m.active);
  const activeResources = (resources.data ?? []).filter((r) => r.active && !r.archived_at);
  const resourceValue = activeResources.some((r) => r.id === resourceId) ? resourceId : '';

  const buildInput = (): CreateJobInput | string => {
    if (!customer) return 'Choose a customer.';
    const lines = pricing.data?.lines ?? [];
    if (selected.length > 0) {
      if (!categoryId && !noSizes) return 'Choose the vehicle size to price the services.';
      if (!pricing.data || pricing.isFetching)
        return 'Prices are still loading. Try again in a moment.';
      if (lines.some((l) => l.unit_price_cents === null)) {
        return 'Some services have no price for this vehicle size. Remove them or set a price in the catalog.';
      }
    }
    let scheduled: { start: string | null; end: string | null } = { start: null, end: null };
    if (mode === 'now') {
      const result = scheduleToUtc(start, end, timezone);
      if ('error' in result) return result.error;
      scheduled = result;
    }
    const suggested = pricing.data?.suggested_discount_value ?? 0;
    const useDiscount = applyMemberDiscount && suggested > 0 && selected.length > 0;
    const mobile = location === 'mobile';
    const text = (v: string) => (mobile && v.trim() ? v.trim() : null);
    const drafts: LineDraft[] = lines.map((l) => ({
      service_id: l.service_id,
      vehicle_id: vehicleId,
      name: l.name,
      description: l.note,
      quantity: 1,
      unit_price_cents: l.unit_price_cents ?? 0,
      discount_cents: 0,
      taxable: l.taxable,
      duration_minutes: l.duration_minutes ?? 0,
    }));
    return {
      job: {
        customer_id: customer.id,
        vehicle_id: vehicleId,
        status: mode === 'now' ? 'scheduled' : 'requested',
        scheduled_start: scheduled.start,
        scheduled_end: scheduled.end,
        location_type: location,
        service_address_line1: text(address.line1),
        service_address_line2: text(address.line2),
        service_city: text(address.city),
        service_region: text(address.region),
        service_postal_code: text(address.postal),
        resource_id: resourceValue || null,
        notes: notes.trim() || null,
        internal_notes: internalNotes.trim() || null,
        discount_kind: useDiscount ? 'percent' : 'none',
        discount_value: useDiscount ? suggested : 0,
        deposit_required_cents: deposit ?? 0,
        sold_by_member_id: soldBy || null,
      },
      lines: drafts,
      assigneeIds: assignees,
    };
  };

  /** The live rule + first visit, for the preview (null while incomplete). */
  const repeatPreview = (): Record<string, unknown> | null => {
    if (!repeating) return null;
    const rule = repeatRuleFields(repeatDraft, start.date);
    const times = scheduleToUtc(start, end, timezone);
    if ('error' in rule || 'error' in times) return null;
    const minutes = spanMinutes(times.start, times.end);
    if (minutes === null || minutes < SERIES_LIMITS.durationMin) return null;
    return { ...rule, start_date: start.date, local_start: start.time, duration_minutes: minutes };
  };

  /** create_job_series payload (P-1), or a message saying what is missing. */
  const buildSeries = (): Record<string, unknown> | string => {
    if (!customer) return 'Choose a customer.';
    if (selected.length === 0) return 'Add at least one service to repeat a job.';
    if (selected.length > SERIES_LIMITS.templateLinesMax) {
      return 'A repeating job can list at most 30 services.';
    }
    if (!noSizes && !vehicleSize) {
      return 'Repeating jobs are priced from the vehicle’s size: choose a vehicle that has a size.';
    }
    const times = scheduleToUtc(start, end, timezone);
    if ('error' in times) return times.error;
    const minutes = spanMinutes(times.start, times.end);
    if (minutes === null || minutes < SERIES_LIMITS.durationMin) {
      return 'Each visit must last at least 15 minutes.';
    }
    const rule = repeatRuleFields(repeatDraft, start.date);
    if ('error' in rule) return rule.error;
    const mobile = location === 'mobile';
    const text = (v: string) => (mobile && v.trim() ? v.trim() : null);
    return {
      customer_id: customer.id,
      ...(vehicleId ? { vehicle_id: vehicleId } : {}),
      location_type: location,
      service_address_line1: text(address.line1),
      service_address_line2: text(address.line2),
      service_city: text(address.city),
      service_region: text(address.region),
      service_postal_code: text(address.postal),
      ...(resourceValue ? { resource_id: resourceValue } : {}),
      ...rule,
      start_date: start.date,
      local_start: start.time,
      duration_minutes: minutes,
      template_lines: selected.map((id) => ({ service_id: id, quantity: 1 })),
      assignee_member_ids: assignees,
      notes: notes.trim() || null,
      internal_notes: internalNotes.trim() || null,
    };
  };

  const submitSeries = async () => {
    const payload = buildSeries();
    if (typeof payload === 'string') {
      setFormError(payload);
      return;
    }
    try {
      const result = await createSeries.mutateAsync(payload);
      toast.success(
        'Repeating job created',
        result.jobs_created === 1
          ? '1 visit scheduled.'
          : `${result.jobs_created} visits scheduled.`,
      );
      await navigate(result.first_job_id ? `/app/jobs/${result.first_job_id}` : '/app/calendar');
    } catch (error) {
      setFormError(errorMessage(error));
      setFormErrorCause(error);
    }
  };

  const submit = async () => {
    setFormError(null);
    setFormErrorCause(null);
    if (repeating && !committed) {
      await submitSeries();
      return;
    }
    const input = committed ?? buildInput();
    if (typeof input === 'string') {
      setFormError(input);
      return;
    }
    try {
      const done = await create.mutateAsync({ input, progress });
      setProgress(done);
      toast.success('Job created');
      if (done.jobId) await navigate(`/app/jobs/${done.jobId}`);
    } catch (error) {
      if (error instanceof CreateJobError) {
        setProgress(error.progress);
        if (error.progress.jobId) setCommitted(input);
      }
      setFormError(errorMessage(error));
      setFormErrorCause(error);
    }
  };

  const partial = progress.jobId !== null;

  return (
    <>
      <PageHeader
        title="New job"
        back={{ to: '/app/jobs', label: 'Jobs' }}
        description={`Times are in the shop’s time zone (${timezone}).`}
      />
      <form
        className="grid grid-cols-1 gap-4 lg:grid-cols-3"
        aria-label="New job"
        onSubmit={(e) => {
          e.preventDefault();
          void submit();
        }}
      >
        <fieldset
          disabled={partial}
          aria-describedby={partial ? 'new-job-locked' : undefined}
          className="flex min-w-0 flex-col gap-4 lg:col-span-2"
        >
          <legend className="sr-only">Job details</legend>
          <CustomerSection
            customer={customer}
            loading={paramCustomer.isFetching}
            onChange={changeCustomer}
          />
          {customer && (
            <VehicleSection
              customerId={customer.id}
              vehicleId={vehicleId}
              categoryId={categoryId}
              categories={categories.data ?? []}
              onVehicle={(v) => {
                setVehicleId(v?.id ?? null);
                setVehicleSize(v?.category_id ?? null);
                if (v?.category_id) setCategoryId(v.category_id);
              }}
              onCategory={setCategoryId}
            />
          )}
          <ServicesSection
            catalog={catalog}
            selected={selected}
            onToggle={(id) =>
              setSelected((ids) => (ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id]))
            }
            pricing={pricing}
            canPrice={customer !== null && (categoryId !== '' || noSizes)}
            applyMemberDiscount={applyMemberDiscount}
            onApplyMemberDiscount={setApplyMemberDiscount}
          />
          <SectionCard title="Schedule">
            <div className="flex flex-col gap-4">
              <RadioGroup<'now' | 'later'>
                label="When"
                hideLabel
                orientation="horizontal"
                value={mode}
                onChange={setMode}
                options={[
                  { value: 'now', label: 'Schedule it' },
                  { value: 'later', label: 'Leave unscheduled (request)' },
                ]}
              />
              {mode === 'now' && (
                <>
                  <div className="grid grid-cols-2 gap-3">
                    <FormField label="Start date" required>
                      <DateInput
                        value={start.date}
                        onChange={(e) => changeStartDate(e.target.value)}
                      />
                    </FormField>
                    <FormField label="Start time" required>
                      <TimeInput
                        value={start.time}
                        onChange={(e) => setStart((s) => ({ ...s, time: e.target.value }))}
                      />
                    </FormField>
                    <FormField label="End date" required>
                      <DateInput
                        value={end.date}
                        onChange={(e) => setEndOverride({ ...end, date: e.target.value })}
                      />
                    </FormField>
                    <FormField label="End time" required>
                      <TimeInput
                        value={end.time}
                        onChange={(e) => setEndOverride({ ...end, time: e.target.value })}
                      />
                    </FormField>
                  </div>
                  <p className="text-muted flex flex-wrap items-center gap-2 text-sm">
                    {minutes > 0
                      ? `Services take about ${formatDuration(minutes)}.`
                      : 'Pick services to size the appointment.'}
                    {endOverride && (
                      <Button size="sm" variant="ghost" onClick={() => setEndOverride(null)}>
                        Match service time
                      </Button>
                    )}
                  </p>
                  <Checkbox
                    label="Repeat this job"
                    description="Regular visits, such as a maintenance wash every two weeks."
                    checked={repeat}
                    onChange={(e) => setRepeat(e.target.checked)}
                  />
                  {repeating && (
                    <section
                      aria-label="Repeat"
                      className="border-line flex flex-col gap-4 border-l-2 pl-4"
                    >
                      <RepeatFields
                        draft={repeatDraft}
                        onChange={setRepeatDraft}
                        anchorDate={start.date}
                      />
                      <SeriesPreview payload={repeatPreview()} timezone={timezone} />
                      <p className="text-muted text-xs">
                        Each visit is priced from your catalog when it’s created, with membership
                        discounts applied. Deposits and other discounts are set on individual
                        visits.
                      </p>
                    </section>
                  )}
                </>
              )}
            </div>
          </SectionCard>
          <SectionCard title="Location">
            <div className="flex flex-col gap-4">
              <RadioGroup<LocationType>
                label="Where"
                hideLabel
                orientation="horizontal"
                value={location}
                onChange={setLocation}
                options={[
                  { value: 'shop', label: 'At the shop' },
                  { value: 'mobile', label: 'Mobile (customer’s address)' },
                ]}
              />
              {location === 'mobile' && (
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  {customer?.address_line1 && (
                    <div className="sm:col-span-2">
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() =>
                          setAddress({
                            line1: customer.address_line1 ?? '',
                            line2: customer.address_line2 ?? '',
                            city: customer.city ?? '',
                            region: customer.region ?? '',
                            postal: customer.postal_code ?? '',
                          })
                        }
                      >
                        Use the customer’s address
                      </Button>
                    </div>
                  )}
                  <FormField label="Street address" className="sm:col-span-2">
                    <Input
                      value={address.line1}
                      maxLength={200}
                      onChange={(e) => setAddress((a) => ({ ...a, line1: e.target.value }))}
                    />
                  </FormField>
                  <FormField label="Apt, suite, etc." className="sm:col-span-2">
                    <Input
                      value={address.line2}
                      maxLength={200}
                      onChange={(e) => setAddress((a) => ({ ...a, line2: e.target.value }))}
                    />
                  </FormField>
                  <FormField label="City">
                    <Input
                      value={address.city}
                      maxLength={100}
                      onChange={(e) => setAddress((a) => ({ ...a, city: e.target.value }))}
                    />
                  </FormField>
                  <div className="grid grid-cols-2 gap-3">
                    <FormField label="State">
                      <Input
                        value={address.region}
                        maxLength={100}
                        onChange={(e) => setAddress((a) => ({ ...a, region: e.target.value }))}
                      />
                    </FormField>
                    <FormField label="ZIP">
                      <Input
                        value={address.postal}
                        maxLength={20}
                        onChange={(e) => setAddress((a) => ({ ...a, postal: e.target.value }))}
                      />
                    </FormField>
                  </div>
                </div>
              )}
            </div>
          </SectionCard>
        </fieldset>

        <div className="flex min-w-0 flex-col gap-4">
          <fieldset
            disabled={partial}
            aria-describedby={partial ? 'new-job-locked' : undefined}
            className="flex min-w-0 flex-col gap-4"
          >
            <legend className="sr-only">Team, notes and deposit</legend>
            <SectionCard title="Team" level={3}>
              <div className="flex flex-col gap-3">
                <FormField label="Bay / van">
                  <Select
                    value={resourceValue}
                    onChange={(e) => setResourceId(e.target.value)}
                    options={[
                      { value: '', label: 'None' },
                      ...activeResources.map((r) => ({ value: r.id, label: r.name })),
                    ]}
                  />
                </FormField>
                <fieldset className="flex flex-col gap-2">
                  <legend className="text-ink mb-1 text-sm font-medium">Assign to</legend>
                  {activeTeam.length === 0 ? (
                    <p className="text-muted text-sm">
                      {team.isPending ? 'Loading team…' : 'No team members yet.'}
                    </p>
                  ) : (
                    activeTeam.map((m) => (
                      <Checkbox
                        key={m.memberId}
                        label={m.name}
                        checked={assignees.includes(m.memberId)}
                        onChange={(e) =>
                          setAssignees((ids) =>
                            e.target.checked
                              ? [...ids, m.memberId]
                              : ids.filter((x) => x !== m.memberId),
                          )
                        }
                      />
                    ))
                  )}
                </fieldset>
                {!repeating && (
                  <FormField label="Sold by" help="Credited with the sale for sales commission.">
                    <Select
                      value={soldBy}
                      onChange={(e) => setSoldBy(e.target.value)}
                      options={[
                        { value: '', label: 'Nobody' },
                        ...activeTeam.map((m) => ({ value: m.memberId, label: m.name })),
                      ]}
                    />
                  </FormField>
                )}
              </div>
            </SectionCard>
            <SectionCard title="Notes & deposit" level={3}>
              <div className="flex flex-col gap-3">
                <FormField label="Notes for the customer">
                  <Textarea
                    rows={3}
                    maxLength={20000}
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                  />
                </FormField>
                <FormField label="Internal notes" help="Only your team sees these.">
                  <Textarea
                    rows={3}
                    maxLength={20000}
                    value={internalNotes}
                    onChange={(e) => setInternalNotes(e.target.value)}
                  />
                </FormField>
                {!repeating && (
                  <FormField label="Deposit required" help="Optional.">
                    <MoneyInput value={deposit} onChange={setDeposit} />
                  </FormField>
                )}
              </div>
            </SectionCard>
          </fieldset>
          <div className="flex flex-col gap-3">
            {formError && (
              <div
                role="alert"
                className="border-danger/40 bg-danger-soft text-danger-ink rounded-control flex gap-2 border p-3 text-sm"
              >
                <AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
                <div className="flex flex-col gap-1">
                  <p>
                    {formError}
                    <BillingErrorLink error={formErrorCause} />
                  </p>
                  {partial && (
                    <p id="new-job-locked">
                      The job is saved, so this form is locked. Retrying saves only the remaining
                      services and team assignments exactly as entered — the job won’t be created
                      twice. To change anything else,{' '}
                      <Link to={`/app/jobs/${progress.jobId}`} className="font-medium underline">
                        open the job
                      </Link>
                      .
                    </p>
                  )}
                </div>
              </div>
            )}
            <Button
              type="submit"
              size="lg"
              loading={create.isPending || createSeries.isPending}
              fullWidth
            >
              {partial ? 'Retry saving' : repeating ? 'Create repeating job' : 'Create job'}
            </Button>
            <Link to="/app/jobs" className={buttonClasses({ variant: 'ghost', fullWidth: true })}>
              Cancel
            </Link>
          </div>
        </div>
      </form>
    </>
  );
}
