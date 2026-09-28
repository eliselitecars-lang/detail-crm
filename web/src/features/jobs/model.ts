/**
 * Pure job helpers (no React, no network): status workflow per role, labels,
 * addresses, list filters <-> URL, storage object names and schedule math.
 * Everything money-related is shown from server values; nothing here
 * computes totals, tax or balances.
 */
import type { Database } from '@/lib/database.types';
import {
  addLocalDays,
  formatDateTime,
  isLocalDate,
  isLocalTime,
  shopLocalToUtcIso,
  utcToShopLocal,
  type LocalDate,
  type LocalTime,
} from '@/lib/dates';
import type { ShopRole } from '@/features/shop/permissions';

export type Enums = Database['public']['Enums'];
export type JobStatus = Enums['job_status'];
export type LocationType = Enums['location_type'];
export type JobPhotoKind = Enums['job_photo_kind'];
export type InspectionKind = Enums['inspection_kind'];
export type VehicleView = Enums['vehicle_view'];
export type DamageKind = Enums['damage_kind'];
export type DiscountKind = Enums['discount_kind'];

export const JOB_STATUSES: readonly JobStatus[] = [
  'requested',
  'scheduled',
  'confirmed',
  'en_route',
  'in_progress',
  'completed',
  'cancelled',
  'no_show',
];

/** The main path shown by the stepper (side exits: cancelled, no_show). */
export const MAIN_PATH: readonly JobStatus[] = [
  'requested',
  'scheduled',
  'confirmed',
  'en_route',
  'in_progress',
  'completed',
];

export const SIDE_EXITS: readonly JobStatus[] = ['cancelled', 'no_show'];

export function isJobStatus(value: string): value is JobStatus {
  return (JOB_STATUSES as readonly string[]).includes(value);
}

/** One row of `job_status_transitions` (reference data, same for every shop). */
export interface StatusTransition {
  from_status: JobStatus;
  to_status: JobStatus;
  direction: string;
  technician_allowed: boolean;
}

/**
 * Transitions the role may take from `from` (mirrors jobs_status_machine):
 * technicians only `technician_allowed` edges (forward, assigned jobs — the
 * server narrows rows), managers and above every edge including backward.
 */
export function allowedTransitions(
  transitions: readonly StatusTransition[],
  from: JobStatus,
  role: ShopRole,
): StatusTransition[] {
  return transitions.filter(
    (t) => t.from_status === from && (role !== 'technician' || t.technician_allowed),
  );
}

export type StepState = 'done' | 'current' | 'upcoming';

export interface StatusStep {
  status: JobStatus;
  state: StepState;
  /** The transition to take when the step is clicked, if allowed. */
  transition: StatusTransition | null;
}

/**
 * Stepper model. Steps before the current one on the main path are "done";
 * for a side exit (cancelled / no-show) nothing is current on the path and
 * steps that reinstate the job stay clickable when the role may.
 */
export function statusSteps(
  current: JobStatus,
  allowed: readonly StatusTransition[],
): StatusStep[] {
  const index = MAIN_PATH.indexOf(current);
  return MAIN_PATH.map((status, i) => ({
    status,
    state: index < 0 ? 'upcoming' : i < index ? 'done' : i === index ? 'current' : 'upcoming',
    transition: allowed.find((t) => t.to_status === status) ?? null,
  }));
}

/** Moving to one of these needs a scheduled time (jobs_schedule_required). */
export function statusNeedsSchedule(status: JobStatus): boolean {
  return status !== 'requested' && status !== 'cancelled';
}

// ---------------------------------------------------------------------------
// Completion gates (P-11, 0073 jobs_70_completion_gates)
// ---------------------------------------------------------------------------

/** job_status_rank (0006): the main path's order; side exits have none. */
export function statusRank(status: JobStatus): number | null {
  const index = MAIN_PATH.indexOf(status);
  return index < 0 ? null : index;
}

/** A move the completion gates check: → completed, or forward into in_progress. */
export function isGatedMove(from: JobStatus, to: JobStatus): boolean {
  if (to === 'completed') return from !== 'completed';
  const rank = statusRank(from);
  return to === 'in_progress' && (rank === null || rank < 4);
}

export interface GateStateLike {
  open_required_items: readonly { id: string; label: string }[];
  before_photos: { required: number; have: number };
  after_photos: { required: number; have: number };
}

export interface GateBlocker {
  key: 'checklist' | 'after_photos' | 'before_photos';
  text: string;
}

/**
 * What blocks the move (mirrors job_gate_blockers_for): required checklist
 * items and "after" photos for completing, "before" photos for starting.
 * Empty when nothing blocks. The server re-checks every move.
 */
export function gateBlockers(state: GateStateLike, from: JobStatus, to: JobStatus): GateBlocker[] {
  if (!isGatedMove(from, to)) return [];
  const out: GateBlocker[] = [];
  const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;
  if (to === 'completed') {
    const open = state.open_required_items;
    if (open.length > 0) {
      out.push({
        key: 'checklist',
        text: `Required checklist ${open.length === 1 ? 'item' : 'items'} not done: ${open.map((i) => i.label).join(', ')}`,
      });
    }
    const { required, have } = state.after_photos;
    if (have < required) {
      out.push({
        key: 'after_photos',
        text: `${plural(required, '“after” photo')} needed (${have} so far)`,
      });
    }
  } else {
    const { required, have } = state.before_photos;
    if (have < required) {
      out.push({
        key: 'before_photos',
        text: `${plural(required, '“before” photo')} needed (${have} so far)`,
      });
    }
  }
  return out;
}

/**
 * The blockers a manager waived (job_gate_overrides.blockers, the blocking
 * part of the gate state that job_gate_blockers_for returned: only the keys
 * that blocked are present), as the same sentences the gate dialog shows.
 * Unknown or malformed parts are skipped.
 */
export function waivedBlockers(raw: unknown): GateBlocker[] {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return [];
  const snapshot = raw as Record<string, unknown>;
  const counts = (value: unknown): { required: number; have: number } | null => {
    if (value === null || typeof value !== 'object') return null;
    const { required, have } = value as Record<string, unknown>;
    return typeof required === 'number' && typeof have === 'number' ? { required, have } : null;
  };
  const items = Array.isArray(snapshot.open_required_items)
    ? snapshot.open_required_items.filter(
        (i): i is { id: string; label: string } =>
          i !== null &&
          typeof i === 'object' &&
          typeof (i as { label?: unknown }).label === 'string',
      )
    : [];
  const none = { required: 0, have: 0 };
  const completing = gateBlockers(
    {
      open_required_items: items,
      after_photos: counts(snapshot.after_photos) ?? none,
      before_photos: none,
    },
    'in_progress',
    'completed',
  );
  const starting = gateBlockers(
    {
      open_required_items: [],
      after_photos: none,
      before_photos: counts(snapshot.before_photos) ?? none,
    },
    'scheduled',
    'in_progress',
  );
  return [...completing, ...starting];
}

// ---------------------------------------------------------------------------
// Deposit follow-ups (P-3)
// ---------------------------------------------------------------------------

export interface FollowupStatusLike {
  enabled: boolean;
  paused: boolean;
  attempts_sent: number;
  max_attempts: number;
  next_at: string | null;
}

/** "Next reminder Tue, Oct 6, 2026 · 9:00 AM · 1 of 3 sent." and friends. */
export function describeFollowup(status: FollowupStatusLike, timeZone: string): string {
  const sent = `${status.attempts_sent} of ${status.max_attempts} sent`;
  if (!status.enabled) return 'Automatic deposit reminders are off.';
  if (status.paused) return `Deposit reminders are paused · ${sent}.`;
  if (status.next_at) return `Next reminder ${formatDateTime(status.next_at, timeZone)} · ${sent}.`;
  if (status.max_attempts > 0 && status.attempts_sent >= status.max_attempts) {
    return `All deposit reminders sent (${sent}).`;
  }
  return 'No deposit reminder is scheduled.';
}

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

export interface NameParts {
  first_name: string | null;
  last_name: string | null;
  company: string | null;
}

export function customerName(c: NameParts | null | undefined): string {
  if (!c) return 'Unknown customer';
  const person = [c.first_name, c.last_name]
    .map((p) => p?.trim())
    .filter(Boolean)
    .join(' ');
  return person || c.company?.trim() || 'Unnamed customer';
}

export interface VehicleParts {
  year: number | null;
  make: string | null;
  model: string | null;
  trim?: string | null;
  color?: string | null;
}

export function vehicleLabel(v: VehicleParts | null | undefined, withDetail = false): string {
  if (!v) return 'No vehicle';
  const base = [v.year?.toString(), v.make, v.model]
    .map((p) => p?.trim())
    .filter(Boolean)
    .join(' ');
  const detail = withDetail
    ? [v.trim, v.color]
        .map((p) => p?.trim())
        .filter(Boolean)
        .join(', ')
    : '';
  const label = base || 'Vehicle';
  return detail ? `${label} (${detail})` : label;
}

export function jobNumberLabel(number: number | null | undefined): string {
  return number === null || number === undefined ? 'Job' : `Job #${number}`;
}

/** "Full detail, Wax +2 more" from line item names (already sorted). */
export function servicesSummary(names: readonly string[], max = 2): string {
  const clean = names.map((n) => n.trim()).filter(Boolean);
  if (clean.length === 0) return '—';
  const shown = clean.slice(0, max).join(', ');
  return clean.length > max ? `${shown} +${clean.length - max} more` : shown;
}

export interface AddressParts {
  line1: string | null;
  line2?: string | null;
  city: string | null;
  region: string | null;
  postalCode: string | null;
}

/** One-line address, or null when there is nothing to show. */
export function formatAddress(a: AddressParts): string | null {
  const street = [a.line1, a.line2]
    .map((p) => p?.trim())
    .filter(Boolean)
    .join(' ');
  const regionPostal = [a.region, a.postalCode]
    .map((p) => p?.trim())
    .filter(Boolean)
    .join(' ');
  const text = [street, a.city?.trim(), regionPostal].filter(Boolean).join(', ');
  return text || null;
}

/** A maps search link for an address (opens the user's maps app on phones). */
export function mapsUrl(address: string): string {
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`;
}

// ---------------------------------------------------------------------------
// Jobs list filters <-> URL
// ---------------------------------------------------------------------------

export type JobSortKey = 'when' | 'number' | 'total';

export interface JobFilters {
  statuses: JobStatus[];
  /** Shop-local inclusive dates ("yyyy-MM-dd"). */
  from: LocalDate | null;
  to: LocalDate | null;
  assigneeId: string | null;
  search: string;
  sort: JobSortKey;
  ascending: boolean;
  page: number;
}

export const DEFAULT_JOB_FILTERS: JobFilters = {
  statuses: [],
  from: null,
  to: null,
  assigneeId: null,
  search: '',
  sort: 'when',
  ascending: false,
  page: 1,
};

const SORT_KEYS: readonly JobSortKey[] = ['when', 'number', 'total'];

export function parseJobFilters(params: URLSearchParams): JobFilters {
  const statuses = (params.get('status') ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(isJobStatus);
  const from = params.get('from');
  const to = params.get('to');
  const sort = params.get('sort');
  const page = Number(params.get('page'));
  return {
    statuses: Array.from(new Set(statuses)),
    from: from && isLocalDate(from) ? from : null,
    to: to && isLocalDate(to) ? to : null,
    assigneeId: params.get('assignee') || null,
    search: (params.get('q') ?? '').slice(0, 100),
    sort: SORT_KEYS.find((k) => k === sort) ?? 'when',
    ascending: params.get('dir') === 'asc',
    page: Number.isInteger(page) && page > 0 ? page : 1,
  };
}

export function jobFiltersToParams(f: JobFilters): URLSearchParams {
  const params = new URLSearchParams();
  if (f.statuses.length > 0) params.set('status', f.statuses.join(','));
  if (f.from) params.set('from', f.from);
  if (f.to) params.set('to', f.to);
  if (f.assigneeId) params.set('assignee', f.assigneeId);
  if (f.search.trim()) params.set('q', f.search.trim());
  if (f.sort !== 'when') params.set('sort', f.sort);
  if (f.ascending) params.set('dir', 'asc');
  if (f.page > 1) params.set('page', String(f.page));
  return params;
}

export function hasActiveFilters(f: JobFilters): boolean {
  return (
    f.statuses.length > 0 ||
    f.from !== null ||
    f.to !== null ||
    f.assigneeId !== null ||
    f.search.trim() !== ''
  );
}

// ---------------------------------------------------------------------------
// Schedule math (all in the shop's timezone)
// ---------------------------------------------------------------------------

export interface LocalDateTime {
  date: LocalDate;
  time: LocalTime;
}

/** Shop-local start + minutes → shop-local end (DST-correct via UTC). */
export function addMinutesLocal(
  start: LocalDateTime,
  minutes: number,
  timeZone: string,
): LocalDateTime | null {
  if (!isLocalDate(start.date) || !isLocalTime(start.time)) return null;
  const startMs = Date.parse(shopLocalToUtcIso(start.date, start.time, timeZone));
  return utcToShopLocal(new Date(startMs + minutes * 60_000), timeZone);
}

/** Validated shop-local start/end → UTC ISO pair, or an error message. */
export function scheduleToUtc(
  start: LocalDateTime,
  end: LocalDateTime,
  timeZone: string,
): { start: string; end: string } | { error: string } {
  if (!isLocalDate(start.date) || !isLocalTime(start.time)) {
    return { error: 'Enter a start date and time.' };
  }
  if (!isLocalDate(end.date) || !isLocalTime(end.time)) {
    return { error: 'Enter an end date and time.' };
  }
  const startIso = shopLocalToUtcIso(start.date, start.time, timeZone);
  const endIso = shopLocalToUtcIso(end.date, end.time, timeZone);
  const span = Date.parse(endIso) - Date.parse(startIso);
  if (span <= 0) return { error: 'The end must be after the start.' };
  if (span > 31 * 86_400_000) return { error: 'A job can span at most 31 days.' };
  return { start: startIso, end: endIso };
}

/** Default schedule when nothing was chosen: tomorrow 9:00 for an hour. */
export function defaultSchedule(today: LocalDate): { start: LocalDateTime; end: LocalDateTime } {
  const date = addLocalDays(today, 1);
  return { start: { date, time: '09:00' }, end: { date, time: '10:00' } };
}

export function sumDurations(values: readonly (number | null | undefined)[]): number {
  return values.reduce<number>((acc, v) => acc + (typeof v === 'number' && v > 0 ? v : 0), 0);
}

export function formatDuration(minutes: number): string {
  if (minutes <= 0) return '0 min';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} min`;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

// ---------------------------------------------------------------------------
// Storage object names (SNAPSHOT: storage.objects policies)
// ---------------------------------------------------------------------------

const IMAGE_EXT: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/heif': 'heif',
};

export const PHOTO_MIME_TYPES = Object.keys(IMAGE_EXT);
export const PHOTO_MAX_BYTES = 20 * 1024 * 1024;

export function photoExtension(file: Pick<File, 'type' | 'name'>): string | null {
  const byType = IMAGE_EXT[file.type];
  if (byType) return byType;
  const match = /\.([a-z0-9]{2,5})$/i.exec(file.name);
  const ext = match?.[1]?.toLowerCase();
  if (!ext) return null;
  const normalized = ext === 'jpeg' ? 'jpg' : ext;
  return Object.values(IMAGE_EXT).includes(normalized) ? normalized : null;
}

/** Why a file can't be uploaded as a job photo, or null. */
export function photoProblem(file: Pick<File, 'type' | 'name' | 'size'>): string | null {
  if (!photoExtension(file)) return 'Choose a JPEG, PNG, WebP or HEIC image.';
  if (file.size > PHOTO_MAX_BYTES) return 'Photos can be at most 20 MB.';
  return null;
}

/** job-photos bucket: `<shop_id>/<job_id>/<uuid>.<ext>` (checked by job_photos_validate). */
export function jobPhotoPath(shopId: string, jobId: string, ext: string, id: string): string {
  return `${shopId}/${jobId}/${id}.${ext}`;
}

/** signatures bucket: `<shop_id>/<folder>/<record id>/<uuid>.png` (staff upload). */
export function signaturePath(
  shopId: string,
  folder: 'inspections' | 'form-submissions',
  recordId: string,
  id: string,
): string {
  return `${shopId}/${folder}/${recordId}/${id}.png`;
}

/** Public form link for a submission token (the /f/:token page). */
export function formLink(origin: string, token: string): string {
  return `${origin.replace(/\/$/, '')}/f/${token}`;
}

/** A video's length: 65 → "1:05" (null when unknown). */
export function formatVideoLength(seconds: number | null | undefined): string | null {
  if (seconds === null || seconds === undefined || seconds <= 0) return null;
  const m = Math.floor(seconds / 60);
  const s = Math.round(seconds % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

export const PHOTO_KIND_LABELS: Record<JobPhotoKind, string> = {
  before: 'Before',
  after: 'After',
  inspection: 'Inspection',
  other: 'Other',
};

export const VEHICLE_VIEWS: readonly VehicleView[] = [
  'front',
  'rear',
  'left',
  'right',
  'top',
  'interior',
];

export const VIEW_LABELS: Record<VehicleView, string> = {
  front: 'Front',
  rear: 'Rear',
  left: 'Driver side',
  right: 'Passenger side',
  top: 'Top',
  interior: 'Interior',
};

export const DAMAGE_KINDS: readonly DamageKind[] = [
  'scratch',
  'dent',
  'chip',
  'crack',
  'stain',
  'swirl',
  'other',
];

export const DAMAGE_LABELS: Record<DamageKind, string> = {
  scratch: 'Scratch',
  dent: 'Dent',
  chip: 'Chip',
  crack: 'Crack',
  stain: 'Stain',
  swirl: 'Swirl marks',
  other: 'Other',
};

/** Clamp a diagram tap to the 0..1 range the database accepts. */
export function clampUnit(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(1, Math.max(0, Math.round(value * 1000) / 1000));
}

// ---------------------------------------------------------------------------
// Inspection details (mileage / fuel / notes)
// ---------------------------------------------------------------------------

export interface InspectionDetailsDraft {
  mileage: string;
  fuel: string;
  notes: string;
}

/** Form strings → the inspection columns, or a user-facing error. */
export function parseInspectionDetails(draft: InspectionDetailsDraft):
  | {
      ok: true;
      details: { mileage: number | null; fuel_level: number | null; notes: string | null };
    }
  | { ok: false; error: string } {
  const m = draft.mileage.trim() === '' ? null : Number(draft.mileage.trim());
  const f = draft.fuel.trim() === '' ? null : Number(draft.fuel.trim());
  if (m !== null && (!Number.isInteger(m) || m < 0 || m > 9_999_999)) {
    return { ok: false, error: 'Mileage must be a whole number.' };
  }
  if (f !== null && (!Number.isInteger(f) || f < 0 || f > 100)) {
    return { ok: false, error: 'Fuel level is a percentage from 0 to 100.' };
  }
  return { ok: true, details: { mileage: m, fuel_level: f, notes: draft.notes.trim() || null } };
}

/** Server row → form strings. */
export function inspectionDetailsDraft(row: {
  mileage: number | null;
  fuel_level: number | null;
  notes: string | null;
}): InspectionDetailsDraft {
  return {
    mileage: row.mileage?.toString() ?? '',
    fuel: row.fuel_level?.toString() ?? '',
    notes: row.notes ?? '',
  };
}

// ---------------------------------------------------------------------------
// Line-item ordering
// ---------------------------------------------------------------------------

/**
 * The job's line ids after moving the line at `index` one step up (-1) or
 * down (+1), for reorder_job_line_items (which renumbers sort 0..n-1 in one
 * transaction). null when the move would leave the list.
 */
export function movedLineOrder(
  rows: readonly { id: string }[],
  index: number,
  delta: -1 | 1,
): string[] | null {
  const target = index + delta;
  if (index < 0 || index >= rows.length || target < 0 || target >= rows.length) return null;
  const order = rows.map((row) => row.id);
  const [moved] = order.splice(index, 1);
  if (moved === undefined) return null;
  order.splice(target, 0, moved);
  return order;
}
