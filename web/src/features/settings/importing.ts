/**
 * CSV import (P-5): column mapping and row building for import_customers /
 * import_services (0087). The server validates every row and reports what
 * it would do (dry run) or did; the web only maps columns, converts money
 * text to whole cents and splits the file into chunks.
 */
import Papa from 'papaparse';
import { stripFormulaGuard } from '@/lib/csv';
import { parseMoneyInput } from '@/lib/money';

export type ImportKind = 'customers' | 'services';

export interface ImportTarget {
  /** Mapping value: a server key, "vehicle.<key>", "price.<size>" or "full_name". */
  id: string;
  label: string;
  /** Header spellings that auto-match (normalised: lowercase letters and digits). */
  aliases: readonly string[];
  group: string;
}

/** Normalised header: "E-mail Address" → "emailaddress". */
export function normalizeHeader(header: string): string {
  return header
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

const CUSTOMER_TARGETS: readonly ImportTarget[] = [
  {
    id: 'full_name',
    label: 'Full name (split into first / last)',
    aliases: ['name', 'fullname', 'customername', 'customer', 'clientname', 'client'],
    group: 'Customer',
  },
  {
    id: 'first_name',
    label: 'First name',
    aliases: ['firstname', 'first', 'givenname', 'fname'],
    group: 'Customer',
  },
  {
    id: 'last_name',
    label: 'Last name',
    aliases: ['lastname', 'last', 'surname', 'familyname', 'lname'],
    group: 'Customer',
  },
  {
    id: 'company',
    label: 'Company',
    aliases: ['company', 'companyname', 'business', 'organization', 'organisation'],
    group: 'Customer',
  },
  { id: 'email', label: 'Email', aliases: ['email', 'emailaddress', 'mail'], group: 'Customer' },
  {
    id: 'phone',
    label: 'Phone',
    aliases: [
      'phone',
      'phonenumber',
      'mobile',
      'mobilephone',
      'cell',
      'cellphone',
      'telephone',
      'tel',
    ],
    group: 'Customer',
  },
  {
    id: 'address_line1',
    label: 'Address line 1',
    aliases: ['address', 'addressline1', 'address1', 'street', 'streetaddress'],
    group: 'Customer',
  },
  {
    id: 'address_line2',
    label: 'Address line 2',
    aliases: ['addressline2', 'address2', 'apt', 'suite', 'unit'],
    group: 'Customer',
  },
  { id: 'city', label: 'City', aliases: ['city', 'town'], group: 'Customer' },
  {
    id: 'region',
    label: 'State / region',
    aliases: ['state', 'region', 'province', 'county'],
    group: 'Customer',
  },
  {
    id: 'postal_code',
    label: 'Postal code',
    aliases: ['zip', 'zipcode', 'postalcode', 'postcode'],
    group: 'Customer',
  },
  {
    id: 'country',
    label: 'Country (2 letters)',
    aliases: ['country', 'countrycode'],
    group: 'Customer',
  },
  { id: 'notes', label: 'Notes', aliases: ['notes', 'note', 'comments'], group: 'Customer' },
  {
    id: 'tags',
    label: 'Tags (separated by ; or ,)',
    aliases: ['tags', 'tag', 'labels'],
    group: 'Customer',
  },
  {
    id: 'lifecycle',
    label: 'Lead or customer',
    aliases: ['lifecycle', 'status', 'type'],
    group: 'Customer',
  },
  {
    id: 'sms_opt_in',
    label: 'Agreed to texts (yes / no)',
    aliases: ['smsoptin', 'textoptin', 'smsconsent', 'textconsent', 'acceptssms'],
    group: 'Customer',
  },
  {
    id: 'email_opt_in',
    label: 'Agreed to emails (yes / no)',
    aliases: ['emailoptin', 'emailconsent', 'acceptsemail', 'acceptsmarketing', 'newsletter'],
    group: 'Customer',
  },
  { id: 'vehicle.year', label: 'Vehicle year', aliases: ['year', 'vehicleyear'], group: 'Vehicle' },
  { id: 'vehicle.make', label: 'Vehicle make', aliases: ['make', 'vehiclemake'], group: 'Vehicle' },
  {
    id: 'vehicle.model',
    label: 'Vehicle model',
    aliases: ['model', 'vehiclemodel'],
    group: 'Vehicle',
  },
  { id: 'vehicle.trim', label: 'Vehicle trim', aliases: ['trim', 'vehicletrim'], group: 'Vehicle' },
  {
    id: 'vehicle.color',
    label: 'Vehicle color',
    aliases: ['color', 'colour', 'vehiclecolor', 'vehiclecolour'],
    group: 'Vehicle',
  },
  {
    id: 'vehicle.license_plate',
    label: 'License plate',
    aliases: ['licenseplate', 'plate', 'licence', 'licenceplate', 'platenumber'],
    group: 'Vehicle',
  },
  { id: 'vehicle.vin', label: 'VIN', aliases: ['vin', 'vinnumber'], group: 'Vehicle' },
  {
    id: 'vehicle.category',
    label: 'Vehicle size (category name)',
    aliases: ['vehiclesize', 'size', 'vehiclecategory', 'category'],
    group: 'Vehicle',
  },
];

const SERVICE_BASE_TARGETS: readonly ImportTarget[] = [
  {
    id: 'name',
    label: 'Name (required)',
    aliases: ['name', 'servicename', 'service', 'title', 'item'],
    group: 'Service',
  },
  {
    id: 'category',
    label: 'Category',
    aliases: ['category', 'group', 'servicecategory'],
    group: 'Service',
  },
  {
    id: 'kind',
    label: 'Type (service, package, add-on, product)',
    aliases: ['kind', 'type', 'servicetype'],
    group: 'Service',
  },
  {
    id: 'description',
    label: 'Description',
    aliases: ['description', 'details', 'desc'],
    group: 'Service',
  },
  {
    id: 'duration_minutes',
    label: 'Duration (minutes)',
    aliases: ['duration', 'durationminutes', 'minutes', 'time'],
    group: 'Service',
  },
  { id: 'taxable', label: 'Taxable (yes / no)', aliases: ['taxable', 'tax'], group: 'Service' },
  {
    id: 'online_bookable',
    label: 'Bookable online (yes / no)',
    aliases: ['onlinebookable', 'bookable', 'online', 'bookonline'],
    group: 'Service',
  },
  {
    id: 'price.base',
    label: 'Price (all sizes)',
    aliases: ['price', 'baseprice', 'amount', 'cost', 'rate'],
    group: 'Prices',
  },
];

/** Import targets; services get one price column per vehicle size. */
export function importTargets(
  kind: ImportKind,
  vehicleSizes: readonly string[] = [],
): ImportTarget[] {
  if (kind === 'customers') return [...CUSTOMER_TARGETS];
  return [
    ...SERVICE_BASE_TARGETS,
    ...vehicleSizes.map((size) => ({
      id: `price.${size}`,
      label: `Price: ${size}`,
      aliases: [
        `price${normalizeHeader(size)}`,
        normalizeHeader(size),
        `${normalizeHeader(size)}price`,
      ],
      group: 'Prices',
    })),
  ];
}

/** header → target id ('' = don't import). */
export type ImportMapping = Record<string, string>;

/**
 * Suggested mapping: a saved choice for the same header wins, then an exact
 * id / label / alias match. Each target is used once (first header wins).
 */
export function autoMap(
  headers: readonly string[],
  targets: readonly ImportTarget[],
  saved: ImportMapping = {},
): ImportMapping {
  const byId = new Set(targets.map((t) => t.id));
  const used = new Set<string>();
  const mapping: ImportMapping = {};
  for (const header of headers) {
    const remembered = saved[header];
    if (
      remembered !== undefined &&
      (remembered === '' || byId.has(remembered)) &&
      !used.has(remembered)
    ) {
      mapping[header] = remembered;
      if (remembered) used.add(remembered);
    }
  }
  for (const header of headers) {
    if (mapping[header] !== undefined) continue;
    const norm = normalizeHeader(header);
    const match = targets.find(
      (t) =>
        !used.has(t.id) &&
        (normalizeHeader(t.id) === norm ||
          normalizeHeader(t.label) === norm ||
          t.aliases.some((a) => normalizeHeader(a) === norm)),
    );
    mapping[header] = match?.id ?? '';
    if (match) used.add(match.id);
  }
  return mapping;
}

/** Targets chosen for more than one column. */
export function duplicateTargets(mapping: ImportMapping): string[] {
  const seen = new Map<string, number>();
  for (const target of Object.values(mapping)) {
    if (target) seen.set(target, (seen.get(target) ?? 0) + 1);
  }
  return [...seen.entries()].filter(([, n]) => n > 1).map(([t]) => t);
}

export interface BuiltRow {
  /** 1-based data row in the file (the header is row 0). */
  line: number;
  payload: Record<string, unknown>;
}

export interface LocalRowError {
  line: number;
  message: string;
}

/** "Jane Q. Public" → { first_name: "Jane Q.", last_name: "Public" }. */
export function splitFullName(full: string): { first_name?: string; last_name?: string } {
  const parts = full.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return {};
  if (parts.length === 1) return { first_name: parts[0] };
  return { first_name: parts.slice(0, -1).join(' '), last_name: parts[parts.length - 1] };
}

const SERVICE_KINDS = ['service', 'package', 'addon', 'product'] as const;

/**
 * "Add-on", "add on", "ADDON" → "addon"; "Service" → "service". Anything else
 * is sent as typed, so the server's row error names the value.
 */
export function normalizeServiceKind(value: string): string {
  const norm = normalizeHeader(value);
  return (SERVICE_KINDS as readonly string[]).includes(norm) ? norm : value;
}

/**
 * CSV records → import rows. Blank cells are left out (never overwrite),
 * vehicle columns become `vehicle {…}`, price columns become
 * `prices {size: cents}` (money text such as "$1,299.00" → 129900).
 * Rows with no mapped value are skipped; unreadable prices are local errors.
 * The apostrophe our exports put before formula-like cells is removed, and a
 * service type is written the way the server spells it ("Add-on" → "addon").
 */
export function buildImportRows(
  records: readonly Record<string, string | undefined>[],
  mapping: ImportMapping,
): { rows: BuiltRow[]; errors: LocalRowError[]; blank: number } {
  const rows: BuiltRow[] = [];
  const errors: LocalRowError[] = [];
  let blank = 0;
  records.forEach((record, index) => {
    const line = index + 1;
    const payload: Record<string, unknown> = {};
    const vehicle: Record<string, string> = {};
    const prices: Record<string, number> = {};
    const problems: string[] = [];
    for (const [header, target] of Object.entries(mapping)) {
      if (!target) continue;
      // Exports guard cells that look like formulas with an apostrophe; drop it.
      const value = stripFormulaGuard((record[header] ?? '').trim()).trim();
      if (value === '') continue;
      if (target === 'full_name') {
        const split = splitFullName(value);
        if (split.first_name && payload.first_name === undefined)
          payload.first_name = split.first_name;
        if (split.last_name && payload.last_name === undefined) payload.last_name = split.last_name;
      } else if (target.startsWith('vehicle.')) {
        vehicle[target.slice('vehicle.'.length)] = value;
      } else if (target.startsWith('price.')) {
        const size = target.slice('price.'.length);
        const cents = parseMoneyInput(value);
        if (cents === null || cents < 0) problems.push(`"${value}" isn’t a price (${header})`);
        else prices[size] = cents;
      } else if (target === 'kind') {
        payload.kind = normalizeServiceKind(value);
      } else {
        payload[target] = value;
      }
    }
    if (Object.keys(vehicle).length > 0) payload.vehicle = vehicle;
    if (Object.keys(prices).length > 0) payload.prices = prices;
    if (problems.length > 0) {
      errors.push({ line, message: problems.join('; ') });
      return;
    }
    if (Object.keys(payload).length === 0) {
      blank += 1;
      return;
    }
    rows.push({ line, payload });
  });
  return { rows, errors, blank };
}

/** Splits into chunks of `size` (the server accepts at most 1000 rows per call). */
export function chunk<T>(items: readonly T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

export const IMPORT_CHUNK_SIZE = 500;
/** Largest file accepted in the browser. */
export const IMPORT_MAX_BYTES = 10 * 1024 * 1024;
/** Most data rows per import. */
export const IMPORT_MAX_ROWS = 20000;

export interface ParsedCsv {
  headers: string[];
  records: Record<string, string>[];
  /** Readable problems (bad quotes, rows with a different column count). */
  warnings: string[];
}

/**
 * Parses CSV text with a header row (delimiter detected, UTF-8 BOM and blank
 * lines ignored). Blank or repeated headers get unique names.
 */
export function parseCsv(text: string): ParsedCsv {
  const seen = new Map<string, number>();
  const result = Papa.parse<Record<string, string>>(text.replace(/^\uFEFF/, ''), {
    header: true,
    skipEmptyLines: 'greedy',
    transformHeader: (header, index) => {
      const base = header.trim() || `Column ${index + 1}`;
      const count = seen.get(base) ?? 0;
      seen.set(base, count + 1);
      return count === 0 ? base : `${base} (${count + 1})`;
    },
  });
  const headers = result.meta.fields ?? [];
  const warnings = result.errors
    .slice(0, 5)
    .map((e) => (e.row !== undefined ? `Row ${e.row + 1}: ${e.message}` : e.message));
  if (result.errors.length > 5) warnings.push(`…and ${result.errors.length - 5} more.`);
  return { headers, records: result.data, warnings };
}

/** A file's text (UTF-8); FileReader where Blob.text() is missing (older browsers). */
export function readFileText(file: Blob): Promise<string> {
  if (typeof file.text === 'function') return file.text();
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(typeof reader.result === 'string' ? reader.result : '');
    reader.onerror = () => reject(reader.error ?? new Error('The file could not be read.'));
    reader.readAsText(file);
  });
}
