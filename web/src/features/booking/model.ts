/**
 * Booking wizard logic (pure, unit-tested): catalog lookups for the chosen
 * vehicle category, add-on eligibility, the week window for availability,
 * form validation, the create_online_booking payload and mapping server
 * errors back to the step that can fix them. No prices are summed here —
 * the server prices everything.
 */
import { toAppError } from '@/lib/errors';
import { addLocalDays, formatInTz, localDaysBetween, shopToday } from '@/lib/dates';
import { normalizePhone } from '@/lib/phone';
import type { BookingCatalog, CatalogAddon, CatalogService, ShopProfile } from './api';

export type StepId = 'vehicle' | 'services' | 'time' | 'details' | 'review';

export const STEPS: readonly { id: StepId; label: string }[] = [
  { id: 'vehicle', label: 'Vehicle' },
  { id: 'services', label: 'Services' },
  { id: 'time', label: 'Date & time' },
  { id: 'details', label: 'Your details' },
  { id: 'review', label: 'Review' },
];

export type LocationChoice = 'shop' | 'mobile';

export interface VehicleInput {
  categoryId: string | null;
  year: string;
  make: string;
  model: string;
  color: string;
}

export interface DetailsInput {
  firstName: string;
  lastName: string;
  email: string;
  phone: string;
  smsOptIn: boolean;
  emailOptIn: boolean;
  locationType: LocationChoice;
  addressLine1: string;
  addressLine2: string;
  city: string;
  region: string;
  postalCode: string;
  notes: string;
  /** Coupon code the server accepted (applied), or "". */
  couponCode: string;
}

export interface SlotChoice {
  startsAt: string;
  endsAt: string;
}

export interface WizardState {
  vehicle: VehicleInput;
  serviceIds: string[];
  addonIds: string[];
  slot: SlotChoice | null;
  details: DetailsInput;
}

export function defaultLocation(businessType: ShopProfile['business_type']): LocationChoice {
  return businessType === 'mobile' ? 'mobile' : 'shop';
}

export function initialWizardState(profile: ShopProfile): WizardState {
  return {
    vehicle: { categoryId: null, year: '', make: '', model: '', color: '' },
    serviceIds: [],
    addonIds: [],
    slot: null,
    details: {
      firstName: '',
      lastName: '',
      email: '',
      phone: '',
      smsOptIn: false,
      emailOptIn: false,
      locationType: defaultLocation(profile.business_type),
      addressLine1: '',
      addressLine2: '',
      city: '',
      region: '',
      postalCode: '',
      notes: '',
      couponCode: '',
    },
  };
}

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

export interface ItemPrice {
  priceCents: number;
  durationMinutes: number | null;
}

/**
 * The catalog price of an item for a vehicle category, exactly as the
 * server resolved it (category price, else base). null = not offered for
 * that category (or, without a category, no base price).
 */
export function priceFor(
  item: CatalogService | CatalogAddon,
  categoryId: string | null,
): ItemPrice | null {
  if (categoryId === null) {
    return item.base_price_cents === null
      ? null
      : { priceCents: item.base_price_cents, durationMinutes: item.duration_minutes };
  }
  const entry = item.prices.find((p) => p.vehicle_category_id === categoryId);
  return entry
    ? {
        priceCents: entry.price_cents,
        durationMinutes: entry.duration_minutes ?? item.duration_minutes,
      }
    : null;
}

/**
 * Add-ons the server will accept with the chosen services: an add-on must
 * be offered with at least one chosen service (each service lists its
 * add-ons; the catalog already expands "no explicit links" to all add-ons),
 * and it must be priced for the vehicle category.
 */
export function eligibleAddons(
  catalog: BookingCatalog,
  serviceIds: readonly string[],
  categoryId: string | null,
): CatalogAddon[] {
  const offered = new Set<string>();
  for (const service of catalog.services) {
    if (serviceIds.includes(service.id)) for (const id of service.addon_ids) offered.add(id);
  }
  return catalog.addons.filter((a) => offered.has(a.id) && priceFor(a, categoryId) !== null);
}

/** Drops chosen services / add-ons that are no longer valid for the category and services. */
export function pruneSelection(
  catalog: BookingCatalog,
  state: Pick<WizardState, 'serviceIds' | 'addonIds'> & { categoryId: string | null },
): { serviceIds: string[]; addonIds: string[] } {
  const serviceIds = state.serviceIds.filter((id) => {
    const service = catalog.services.find((s) => s.id === id);
    return service !== undefined && priceFor(service, state.categoryId) !== null;
  });
  const allowed = new Set(eligibleAddons(catalog, serviceIds, state.categoryId).map((a) => a.id));
  return { serviceIds, addonIds: state.addonIds.filter((id) => allowed.has(id)) };
}

export interface ServiceGroup {
  id: string | null;
  name: string | null;
  services: CatalogService[];
}

/** Services grouped under their service category (catalog order kept); uncategorised last. */
export function groupServices(catalog: BookingCatalog): ServiceGroup[] {
  const groups: ServiceGroup[] = catalog.service_categories.map((c) => ({
    id: c.id,
    name: c.name,
    services: catalog.services.filter((s) => s.category_id === c.id),
  }));
  const known = new Set(catalog.service_categories.map((c) => c.id));
  const other = catalog.services.filter((s) => s.category_id === null || !known.has(s.category_id));
  if (other.length > 0)
    groups.push({ id: null, name: groups.length > 0 ? 'Other' : null, services: other });
  return groups.filter((g) => g.services.length > 0);
}

// ---------------------------------------------------------------------------
// Availability window
// ---------------------------------------------------------------------------

export const WEEK_DAYS = 7;

export interface WeekWindow {
  from: string;
  to: string;
}

export function weekWindow(start: string): WeekWindow {
  return { from: start, to: addLocalDays(start, WEEK_DAYS - 1) };
}

/** Last shop-local date online booking allows (max_days_ahead), or null when unlimited. */
export function lastBookableDate(
  timeZone: string,
  maxDaysAhead: number | null,
  now = new Date(),
): string | null {
  if (maxDaysAhead === null || maxDaysAhead < 0) return null;
  return addLocalDays(shopToday(timeZone, now), maxDaysAhead);
}

export function canGoToPreviousWeek(start: string, timeZone: string, now = new Date()): boolean {
  return localDaysBetween(shopToday(timeZone, now), start) > 0;
}

export function canGoToNextWeek(start: string, lastDate: string | null): boolean {
  if (lastDate === null) return true;
  return localDaysBetween(addLocalDays(start, WEEK_DAYS), lastDate) >= 0;
}

/** Previous week start, never before today. */
export function previousWeekStart(start: string, timeZone: string, now = new Date()): string {
  const today = shopToday(timeZone, now);
  const candidate = addLocalDays(start, -WEEK_DAYS);
  return localDaysBetween(today, candidate) < 0 ? today : candidate;
}

export interface DaySlots {
  date: string;
  slots: SlotChoice[];
}

/** Buckets slots by their SHOP-local date across every day of the window. */
export function groupSlotsByDay(
  slots: readonly { starts_at: string; ends_at: string }[],
  timeZone: string,
  window: WeekWindow,
): DaySlots[] {
  const days: DaySlots[] = [];
  const count = localDaysBetween(window.from, window.to) + 1;
  for (let i = 0; i < count; i += 1) days.push({ date: addLocalDays(window.from, i), slots: [] });
  const byDate = new Map(days.map((d) => [d.date, d]));
  const sorted = [...slots].sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
  for (const slot of sorted) {
    const day = byDate.get(formatInTz(slot.starts_at, timeZone, 'yyyy-MM-dd'));
    day?.slots.push({ startsAt: slot.starts_at, endsAt: slot.ends_at });
  }
  return days;
}

// ---------------------------------------------------------------------------
// Validation (mirrors the server's payload rules; the server re-checks all)
// ---------------------------------------------------------------------------

export type FieldErrors<K extends string> = Partial<Record<K, string>>;

export function validateVehicle(
  vehicle: VehicleInput,
  requireCategory: boolean,
  currentYear = new Date().getFullYear(),
): FieldErrors<keyof VehicleInput> {
  const errors: FieldErrors<keyof VehicleInput> = {};
  if (requireCategory && !vehicle.categoryId) errors.categoryId = 'Choose your vehicle type.';
  const year = vehicle.year.trim();
  if (year !== '') {
    const n = Number(year);
    if (!/^\d{4}$/.test(year) || n < 1886 || n > currentYear + 2) {
      errors.year = `Enter a year between 1886 and ${currentYear + 2}.`;
    }
  }
  if (!vehicle.make.trim()) errors.make = 'Make is required.';
  else if (vehicle.make.trim().length > 60) errors.make = 'Make must be 60 characters or fewer.';
  if (!vehicle.model.trim()) errors.model = 'Model is required.';
  else if (vehicle.model.trim().length > 60) errors.model = 'Model must be 60 characters or fewer.';
  if (vehicle.color.trim().length > 40) errors.color = 'Color must be 40 characters or fewer.';
  return errors;
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const COUPON_RE = /^[A-Za-z0-9_-]{1,40}$/;

/**
 * The server (create_online_booking → normalize_phone_e164 with the shop's
 * country) reads bare 10-digit numbers as NANP only for US/CA shops; anywhere
 * else it needs the international "+" form, the same rule lib/phone applies.
 * Say so, rather than a bare "invalid", to customers of non-NANP shops.
 */
export function isNanpCountry(country: string | null): boolean {
  return ['US', 'CA'].includes((country ?? 'US').trim().toUpperCase());
}

export function phoneHint(country: string | null): string {
  return isNanpCountry(country)
    ? 'Enter a valid phone number.'
    : 'Enter your number with the country code, starting with + (e.g. +44 7700 900123).';
}

export function validateDetails(
  details: DetailsInput,
  businessType: ShopProfile['business_type'],
  /** Shop country (public_shop_profile.country); drives the phone hint. */
  country: string | null = 'US',
): FieldErrors<keyof DetailsInput> {
  const errors: FieldErrors<keyof DetailsInput> = {};
  const max = (key: keyof DetailsInput, value: string, limit: number, label: string) => {
    if (value.trim().length > limit) errors[key] = `${label} must be ${limit} characters or fewer.`;
  };
  if (!details.firstName.trim()) errors.firstName = 'First name is required.';
  max('firstName', details.firstName, 100, 'First name');
  max('lastName', details.lastName, 100, 'Last name');
  const email = details.email.trim();
  if (!email) errors.email = 'Email is required.';
  else if (!EMAIL_RE.test(email) || email.length > 254)
    errors.email = 'Enter a valid email address.';
  if (details.phone.trim() && normalizePhone(details.phone) === null) {
    errors.phone = phoneHint(country);
  }
  if (details.smsOptIn && !details.phone.trim()) {
    errors.phone = 'Add a mobile number to get text updates.';
  }
  const mobile = locationFor(details, businessType) === 'mobile';
  if (mobile) {
    if (!details.addressLine1.trim()) errors.addressLine1 = 'Street address is required.';
    max('addressLine1', details.addressLine1, 200, 'Street address');
    max('addressLine2', details.addressLine2, 200, 'Address line 2');
    if (!details.city.trim()) errors.city = 'City is required.';
    max('city', details.city, 100, 'City');
    max('region', details.region, 100, 'State / region');
    if (!details.postalCode.trim()) errors.postalCode = 'ZIP / postal code is required.';
    max('postalCode', details.postalCode, 20, 'ZIP / postal code');
  }
  max('notes', details.notes, 2000, 'Notes');
  return errors;
}

/** Where the work happens given what the shop offers. */
export function locationFor(
  details: DetailsInput,
  businessType: ShopProfile['business_type'],
): LocationChoice {
  if (businessType === 'mobile') return 'mobile';
  if (businessType === 'fixed') return 'shop';
  return details.locationType;
}

// ---------------------------------------------------------------------------
// Payload
// ---------------------------------------------------------------------------

/** create_online_booking p_payload (0042). Deliberately has no price fields. */
export type BookingPayload = {
  customer: {
    first_name: string;
    last_name: string | null;
    email: string;
    phone: string | null;
    sms_opt_in: boolean;
    email_opt_in: boolean;
  };
  vehicle: {
    year: number | null;
    make: string;
    model: string;
    color: string | null;
    /** Omitted when the shop has no vehicle categories (the server prices by base price). */
    category_id?: string;
  };
  service_ids: string[];
  addon_ids: string[];
  starts_at: string;
  location: {
    type: LocationChoice;
    address_line1?: string;
    address_line2?: string | null;
    city?: string;
    region?: string | null;
    postal_code?: string;
  };
  notes: string | null;
  coupon_code: string | null;
};

const orNull = (value: string) => (value.trim() === '' ? null : value.trim());

export function buildPayload(
  state: WizardState,
  businessType: ShopProfile['business_type'],
): BookingPayload {
  if (!state.slot) throw new Error('A time must be chosen before booking.');
  const { details, vehicle } = state;
  const phone = orNull(details.phone);
  const location = locationFor(details, businessType);
  return {
    customer: {
      first_name: details.firstName.trim(),
      last_name: orNull(details.lastName),
      email: details.email.trim().toLowerCase(),
      phone: phone === null ? null : (normalizePhone(phone) ?? phone),
      sms_opt_in: phone !== null && details.smsOptIn,
      email_opt_in: details.emailOptIn,
    },
    vehicle: {
      year: vehicle.year.trim() === '' ? null : Number(vehicle.year.trim()),
      make: vehicle.make.trim(),
      model: vehicle.model.trim(),
      color: orNull(vehicle.color),
      ...(vehicle.categoryId ? { category_id: vehicle.categoryId } : {}),
    },
    service_ids: [...state.serviceIds],
    addon_ids: [...state.addonIds],
    starts_at: state.slot.startsAt,
    location:
      location === 'mobile'
        ? {
            type: 'mobile',
            address_line1: details.addressLine1.trim(),
            address_line2: orNull(details.addressLine2),
            city: details.city.trim(),
            region: orNull(details.region),
            postal_code: details.postalCode.trim(),
          }
        : { type: 'shop' },
    notes: orNull(details.notes),
    coupon_code: orNull(details.couponCode),
  };
}

// ---------------------------------------------------------------------------
// Server errors → the step that can fix them
// ---------------------------------------------------------------------------

export type BookingErrorKind =
  'slot_taken' | 'closed' | 'rate_limited' | 'not_found' | 'field' | 'other';

export interface ClassifiedBookingError {
  kind: BookingErrorKind;
  message: string;
  step: StepId | null;
}

/**
 * create_online_booking error codes (0042 header): 23P01, 55000, PT429,
 * PT404 (unknown shop or saved vehicle; older servers raised P0002), 22023.
 */
export function classifyBookingError(error: unknown): ClassifiedBookingError {
  const appError = toAppError(error);
  const code = appError.code ?? '';
  const message = appError.message;
  if (code === '23P01') {
    return {
      kind: 'slot_taken',
      message: 'Sorry — that time was just booked by someone else. Please choose another time.',
      step: 'time',
    };
  }
  if (code === '55000') return { kind: 'closed', message, step: null };
  if (code === 'PT429' || appError.kind === 'rate_limited') {
    return { kind: 'rate_limited', message, step: null };
  }
  if (code === 'PT404' || code === 'P0002') return { kind: 'not_found', message, step: null };
  if (code === '22023') {
    const text = message.toLowerCase();
    let step: StepId | null = null;
    if (/starts_at|time zone|daylight|time is no longer/.test(text)) step = 'time';
    else if (/not offered for this vehicle/.test(text)) step = 'services';
    else if (
      /service area|address|city|postal|region|mobile service|coupon|name|email|phone|notes|contact/.test(
        text,
      )
    ) {
      step = 'details';
    } else if (/vehicle|vin|license plate/.test(text)) step = 'vehicle';
    else if (/service|add-on/.test(text)) step = 'services';
    return { kind: 'field', message, step };
  }
  return { kind: 'other', message, step: null };
}

/**
 * Whether the booking's totals show a Balance row. booking_public_json derives
 * the balance as `invoice balance ?? job total − paid` regardless of status, so
 * a cancelled or no-show booking would otherwise show the whole job total as
 * owed. Anything genuinely owed on those (e.g. a no-show fee) is invoiced and
 * shown on the invoice card instead. Completed jobs only show a non-zero balance.
 */
export function showsBalance(status: string, balanceCents: number): boolean {
  if (status === 'cancelled' || status === 'no_show') return false;
  if (status === 'completed') return balanceCents > 0;
  return true;
}
