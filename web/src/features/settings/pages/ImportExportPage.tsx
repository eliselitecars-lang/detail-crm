import { Download, FileSpreadsheet, RotateCcw, Upload } from 'lucide-react';
import { useMemo, useState } from 'react';
import { Link } from 'react-router';
import {
  Badge,
  Button,
  DateInput,
  EmptyState,
  FileDropzone,
  FormField,
  RadioGroup,
  SectionCard,
  Select,
  Table,
  useToast,
  type BadgeTone,
  type Column,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { centsCell, downloadCsv, toCsv, type CsvColumn } from '@/lib/csv';
import { readCustomData } from '@/lib/customFields';
import {
  addLocalDays,
  formatDateTime,
  formatInTz,
  isLocalDate,
  localDaysBetween,
  shopToday,
} from '@/lib/dates';
import { fileStem } from '@/lib/download';
import { errorMessage } from '@/lib/errors';
import { readLocal, storageKeys, writeLocal } from '@/lib/storage';
import { useVehicleCategories } from '../api';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { useCustomFields } from '../data/customFields';
import {
  fetchExportCustomers,
  fetchExportJobs,
  fetchExportVehicles,
  ImportInterruptedError,
  useImportBatches,
  useRunImport,
  type ExportCustomer,
  type ExportVehicle,
  type ImportBatch,
  type ImportRowResult,
  type ImportRunResult,
} from '../data/importExport';
import {
  autoMap,
  buildImportRows,
  duplicateTargets,
  importTargets,
  IMPORT_MAX_BYTES,
  IMPORT_MAX_ROWS,
  parseCsv,
  readFileText,
  type ImportKind,
  type ImportMapping,
  type LocalRowError,
  type ParsedCsv,
} from '../importing';

const KIND_LABELS: Record<ImportKind, string> = {
  customers: 'Customers & vehicles',
  services: 'Services & prices',
};

export default function ImportExportPage() {
  return (
    <SettingsSectionLayout section="import-export">
      <ImportCard />
      <RecentImports />
      <ExportCard />
    </SettingsSectionLayout>
  );
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

interface LoadedFile {
  name: string;
  csv: ParsedCsv;
}

function readSavedMapping(shopId: string, kind: ImportKind): ImportMapping {
  try {
    const raw = readLocal(storageKeys.importMapping(shopId, kind));
    const parsed: unknown = raw ? JSON.parse(raw) : {};
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return Object.fromEntries(
        Object.entries(parsed as Record<string, unknown>).filter(
          (e): e is [string, string] => typeof e[1] === 'string',
        ),
      );
    }
  } catch {
    // a broken saved mapping is ignored
  }
  return {};
}

function ImportCard() {
  const { shopId } = useShop();
  const toast = useToast();
  const categories = useVehicleCategories();
  const run = useRunImport();
  const [kind, setKind] = useState<ImportKind>('customers');
  const [file, setFile] = useState<LoadedFile | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);
  const [parsing, setParsing] = useState(false);
  const [mapping, setMapping] = useState<ImportMapping>({});
  const [preview, setPreview] = useState<ImportRunResult | null>(null);
  const [done, setDone] = useState<ImportRunResult | null>(null);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  /** A commit that stopped part-way: only the rest of the file may be sent. */
  const [interrupted, setInterrupted] = useState<ImportInterruptedError | null>(null);
  const locked = run.isPending || interrupted !== null;

  const sizes = useMemo(() => (categories.data ?? []).map((c) => c.name), [categories.data]);
  const targets = useMemo(() => importTargets(kind, sizes), [kind, sizes]);
  const built = useMemo(
    () => (file ? buildImportRows(file.csv.records, mapping) : null),
    [file, mapping],
  );
  const duplicates = duplicateTargets(mapping);
  const mappedCount = Object.values(mapping).filter(Boolean).length;

  const reset = () => {
    setFile(null);
    setMapping({});
    setPreview(null);
    setDone(null);
    setFileError(null);
    setProgress(null);
    setInterrupted(null);
  };

  const changeKind = (next: ImportKind) => {
    setKind(next);
    if (file)
      setMapping(
        autoMap(file.csv.headers, importTargets(next, sizes), readSavedMapping(shopId, next)),
      );
    setPreview(null);
    setDone(null);
  };

  const onFiles = async (files: File[]) => {
    const picked = files[0];
    if (!picked) return;
    setParsing(true);
    setFileError(null);
    setPreview(null);
    setDone(null);
    try {
      const csv = parseCsv(await readFileText(picked));
      if (csv.headers.length === 0 || csv.records.length === 0) {
        setFileError('That file has no rows. The first row must be the column names.');
        return;
      }
      if (csv.records.length > IMPORT_MAX_ROWS) {
        setFileError(
          `That file has ${csv.records.length.toLocaleString('en-US')} rows. Import at most ${IMPORT_MAX_ROWS.toLocaleString('en-US')} at a time — split it into smaller files.`,
        );
        return;
      }
      setFile({ name: picked.name, csv });
      setMapping(autoMap(csv.headers, targets, readSavedMapping(shopId, kind)));
    } catch (error) {
      setFileError(`Couldn’t read that file: ${errorMessage(error)}`);
    } finally {
      setParsing(false);
    }
  };

  const setTarget = (header: string, target: string) => {
    const next = { ...mapping, [header]: target };
    setMapping(next);
    setPreview(null);
    writeLocal(
      storageKeys.importMapping(shopId, kind),
      JSON.stringify({ ...readSavedMapping(shopId, kind), [header]: target }),
    );
  };

  const start = async (dryRun: boolean, resumeFrom: ImportInterruptedError | null = null) => {
    if (!file || !built) return;
    try {
      const result = await run.mutateAsync({
        kind,
        rows: built.rows,
        dryRun,
        fileName: file.name,
        onProgress: (d, total) => setProgress({ done: d, total }),
        ...(resumeFrom
          ? {
              resume: {
                batchId: resumeFrom.partial.batchId,
                from: resumeFrom.savedRows,
                previous: resumeFrom.partial,
              },
            }
          : {}),
      });
      setInterrupted(null);
      if (dryRun) setPreview(result);
      else {
        setDone(result);
        toast.success('Import finished');
      }
    } catch (error) {
      if (!(error instanceof ImportInterruptedError)) {
        toast.error(error);
      } else if (error.savedRows >= error.totalRows) {
        // Every chunk was saved; only a reply got lost.
        setInterrupted(null);
        setDone(error.partial);
        toast.success('Import finished');
      } else {
        setInterrupted(error);
      }
    } finally {
      setProgress(null);
    }
  };

  const canCheck =
    file !== null &&
    built !== null &&
    built.rows.length > 0 &&
    duplicates.length === 0 &&
    mappedCount > 0;
  const needsName =
    kind === 'services'
      ? !Object.values(mapping).includes('name')
      : !Object.values(mapping).some((t) =>
          ['first_name', 'last_name', 'full_name', 'company', 'email', 'phone'].includes(t),
        );

  return (
    <SectionCard
      title="Import from a spreadsheet"
      description="Upload a CSV file (in Excel or Google Sheets: File → Download → CSV). You’ll see exactly what will happen before anything is saved."
    >
      <div className="flex flex-col gap-4">
        <RadioGroup
          label="What are you importing?"
          variant="cards"
          value={kind}
          onChange={(v) => changeKind(v)}
          options={[
            {
              value: 'customers',
              label: KIND_LABELS.customers,
              description:
                'One row per customer, optionally with one vehicle. Existing customers (same email, or same phone) are matched: only their empty fields are filled.',
            },
            {
              value: 'services',
              label: KIND_LABELS.services,
              description:
                'One row per service with its prices. Existing services (same name) keep their prices; only missing ones are added.',
            },
          ]}
          disabled={locked}
        />

        {done ? (
          <ImportDone kind={kind} result={done} onAgain={reset} />
        ) : !file ? (
          <FileDropzone
            accept={['.csv', 'text/csv']}
            maxBytes={IMPORT_MAX_BYTES}
            busy={parsing}
            label="Drop a CSV file here"
            description="Up to 10 MB and 20,000 rows. The first row must be the column names."
            onFiles={(files) => void onFiles(files)}
            onReject={setFileError}
            error={fileError}
          />
        ) : (
          <>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="text-ink text-sm">
                <FileSpreadsheet className="text-muted mr-1 inline size-4" aria-hidden="true" />
                <span className="font-medium">{file.name}</span> ·{' '}
                {file.csv.records.length.toLocaleString('en-US')} rows
              </p>
              <Button
                variant="ghost"
                size="sm"
                leadingIcon={<RotateCcw className="size-4" aria-hidden="true" />}
                onClick={reset}
                disabled={run.isPending}
              >
                Choose another file
              </Button>
            </div>
            {file.csv.warnings.length > 0 && (
              <div
                role="note"
                className="bg-warning-soft text-warning-ink rounded-control px-3 py-2 text-xs"
              >
                <p className="font-medium">Some lines of the file look damaged:</p>
                <ul className="mt-1 list-disc pl-4">
                  {file.csv.warnings.map((w) => (
                    <li key={w}>{w}</li>
                  ))}
                </ul>
              </div>
            )}
            <MappingTable
              csv={file.csv}
              mapping={mapping}
              targets={targets}
              duplicates={duplicates}
              disabled={locked}
              onChange={setTarget}
            />
            {needsName && (
              <p
                role="note"
                className="bg-warning-soft text-warning-ink rounded-control px-3 py-2 text-xs"
              >
                {kind === 'services'
                  ? 'Choose the column with the service name — every service needs one.'
                  : 'Choose at least a name, email or phone column so customers can be created and matched.'}
              </p>
            )}
            {built && built.errors.length > 0 && (
              <p className="text-danger-ink text-sm">
                {built.errors.length} row{built.errors.length === 1 ? '' : 's'} can’t be read and
                will be left out (see the check results).
              </p>
            )}
            {progress && (
              <div className="flex flex-col gap-1" aria-live="polite">
                <progress
                  className="accent-primary h-2 w-full"
                  max={progress.total}
                  value={progress.done}
                  aria-label="Import progress"
                />
                <p className="text-muted text-xs">
                  {progress.done.toLocaleString('en-US')} of{' '}
                  {progress.total.toLocaleString('en-US')} rows
                </p>
              </div>
            )}
            {preview && built && !interrupted && (
              <ImportSummary result={preview} localErrors={built.errors} fileName={file.name} />
            )}
            {interrupted ? (
              <ImportInterrupted
                kind={kind}
                interruption={interrupted}
                busy={run.isPending}
                onResume={() => void start(false, interrupted)}
                onStop={() => {
                  setDone(interrupted.partial);
                  setInterrupted(null);
                }}
              />
            ) : (
              <div className="flex flex-wrap gap-2">
                <Button
                  variant={preview ? 'secondary' : 'primary'}
                  loading={run.isPending && run.variables?.dryRun === true}
                  disabled={!canCheck || run.isPending}
                  onClick={() => void start(true)}
                >
                  {preview ? 'Check again' : 'Check the file'}
                </Button>
                {preview && (
                  <Button
                    leadingIcon={<Upload className="size-4" aria-hidden="true" />}
                    loading={run.isPending && run.variables?.dryRun === false}
                    disabled={
                      run.isPending || preview.counts.created + preview.counts.updated === 0
                    }
                    onClick={() => void start(false)}
                  >
                    Import{' '}
                    {(preview.counts.created + preview.counts.updated).toLocaleString('en-US')} row
                    {preview.counts.created + preview.counts.updated === 1 ? '' : 's'}
                  </Button>
                )}
              </div>
            )}
            <p className="text-muted text-xs">
              Consent: customers are opted in to texts or emails only when the file says yes (yes,
              y, true or 1). Opt-outs are never changed by an import.
            </p>
          </>
        )}
      </div>
    </SectionCard>
  );
}

function MappingTable({
  csv,
  mapping,
  targets,
  duplicates,
  disabled,
  onChange,
}: {
  csv: ParsedCsv;
  mapping: ImportMapping;
  targets: readonly { id: string; label: string; group: string }[];
  duplicates: readonly string[];
  disabled: boolean;
  onChange: (header: string, target: string) => void;
}) {
  const options = [
    { value: '', label: 'Don’t import' },
    ...targets.map((t) => ({ value: t.id, label: `${t.group}: ${t.label}` })),
  ];
  const sample = (header: string) =>
    csv.records.find((r) => (r[header] ?? '').trim() !== '')?.[header]?.trim() ?? '';
  return (
    <div className="flex flex-col gap-2">
      <p className="text-ink text-sm font-medium" id="import-mapping-label">
        Match your columns
      </p>
      <ul
        className="divide-line border-line rounded-card divide-y border"
        aria-labelledby="import-mapping-label"
      >
        {csv.headers.map((header) => {
          const target = mapping[header] ?? '';
          const duplicate = target !== '' && duplicates.includes(target);
          return (
            <li
              key={header}
              className="grid gap-2 px-3 py-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] sm:items-center"
            >
              <div className="min-w-0">
                <p className="text-ink truncate text-sm font-medium">{header}</p>
                <p className="text-muted truncate text-xs">{sample(header) || 'Empty column'}</p>
              </div>
              <div>
                <Select
                  aria-label={`Field for the column ${header}`}
                  value={target}
                  options={options}
                  disabled={disabled}
                  aria-invalid={duplicate ? true : undefined}
                  onChange={(event) => onChange(header, event.target.value)}
                />
                {duplicate && (
                  <p role="alert" className="text-danger-ink mt-1 text-xs font-medium">
                    Another column is already matched to this field.
                  </p>
                )}
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

const ACTION_LABELS: Record<ImportRowResult['action'], string> = {
  create: 'New',
  update: 'Update',
  skip: 'No change',
  error: 'Problem',
};
const ACTION_TONES: Record<ImportRowResult['action'], BadgeTone> = {
  create: 'success',
  update: 'info',
  skip: 'neutral',
  error: 'danger',
};

function problemsCsv(rows: readonly ImportRowResult[], local: readonly LocalRowError[]): string {
  const all = [
    ...local.map((e) => ({ line: e.line, message: e.message })),
    ...rows
      .filter((r) => r.action === 'error')
      .map((r) => ({ line: r.line, message: r.message ?? '' })),
  ].sort((a, b) => a.line - b.line);
  const columns: CsvColumn<{ line: number; message: string }>[] = [
    // +1: the header is line 1 of the file
    { header: 'Line in file', value: (r) => r.line + 1 },
    { header: 'Problem', value: (r) => r.message },
  ];
  return toCsv(columns, all);
}

function ImportSummary({
  result,
  localErrors,
  fileName,
}: {
  result: ImportRunResult;
  localErrors: readonly LocalRowError[];
  fileName: string;
}) {
  const problems = result.counts.errors + localErrors.length;
  const shown = [
    ...localErrors.map<ImportRowResult>((e) => ({
      line: e.line,
      action: 'error',
      vehicleAction: null,
      message: e.message,
    })),
    ...result.rows.filter((r) => r.action !== 'create' || r.vehicleAction === 'create'),
  ]
    .sort((a, b) => a.line - b.line)
    .slice(0, 200);
  const columns: Column<ImportRowResult>[] = [
    { key: 'line', header: 'Line', cell: (r) => r.line + 1, primary: true },
    {
      key: 'action',
      header: 'Result',
      cell: (r) => <Badge tone={ACTION_TONES[r.action]}>{ACTION_LABELS[r.action]}</Badge>,
    },
    {
      key: 'message',
      header: 'Details',
      cell: (r) =>
        [
          r.vehicleAction === 'create'
            ? 'adds a vehicle'
            : r.vehicleAction === 'match'
              ? 'vehicle already on file'
              : null,
          r.message,
        ]
          .filter(Boolean)
          .join(' · ') || '—',
    },
  ];
  return (
    <div className="border-line rounded-card flex flex-col gap-3 border p-3" aria-live="polite">
      <p className="text-ink text-sm font-medium">
        {result.dryRun ? 'Check results (nothing saved yet)' : 'Import results'}
      </p>
      <div className="flex flex-wrap gap-2">
        <Badge tone="success">{result.counts.created} new</Badge>
        <Badge tone="info">{result.counts.updated} updated</Badge>
        <Badge tone="neutral">{result.counts.skipped} unchanged</Badge>
        <Badge tone={problems > 0 ? 'danger' : 'neutral'}>{problems} with problems</Badge>
      </div>
      {problems > 0 && (
        <div>
          <Button
            variant="secondary"
            size="sm"
            leadingIcon={<Download className="size-4" aria-hidden="true" />}
            onClick={() =>
              downloadCsv(
                `${fileStem(fileName.replace(/\.csv$/i, ''), 'import')}-problems.csv`,
                problemsCsv(result.rows, localErrors),
              )
            }
          >
            Download the problems (CSV)
          </Button>
        </div>
      )}
      {shown.length > 0 && (
        <div className="max-h-80 overflow-y-auto">
          <Table
            caption="Rows that update, skip or have a problem"
            columns={columns}
            rows={shown}
            getRowId={(r) => `${r.line}`}
          />
        </div>
      )}
    </div>
  );
}

function ImportInterrupted({
  kind,
  interruption,
  busy,
  onResume,
  onStop,
}: {
  kind: ImportKind;
  interruption: ImportInterruptedError;
  busy: boolean;
  onResume: () => void;
  onStop: () => void;
}) {
  const { savedRows, totalRows } = interruption;
  const remaining = totalRows - savedRows;
  const fmt = (n: number) => n.toLocaleString('en-US');
  return (
    <div
      role="alert"
      className="bg-warning-soft text-warning-ink rounded-control flex flex-col gap-2 px-3 py-3 text-sm"
    >
      <p className="font-medium">
        The import stopped after {fmt(savedRows)} of {fmt(totalRows)} rows.
      </p>
      <p>{interruption.message}</p>
      <p>
        The first {fmt(savedRows)} row{savedRows === 1 ? ' is' : 's are'} saved. Import the
        remaining {fmt(remaining)} to finish — saved rows aren’t sent again.
        {kind === 'customers'
          ? ' Don’t import the whole file again: customers without an email or phone would be added twice.'
          : ''}
      </p>
      <div className="flex flex-wrap gap-2">
        <Button
          leadingIcon={<Upload className="size-4" aria-hidden="true" />}
          loading={busy}
          disabled={busy}
          onClick={onResume}
        >
          Import the remaining {fmt(remaining)} row{remaining === 1 ? '' : 's'}
        </Button>
        <Button variant="secondary" disabled={busy} onClick={onStop}>
          Stop here
        </Button>
      </div>
    </div>
  );
}

function ImportDone({
  kind,
  result,
  onAgain,
}: {
  kind: ImportKind;
  result: ImportRunResult;
  onAgain: () => void;
}) {
  return (
    <div className="flex flex-col gap-3">
      <ImportSummary result={result} localErrors={[]} fileName="import" />
      <div className="flex flex-wrap gap-2">
        <Link
          className="text-primary text-sm underline"
          to={kind === 'customers' ? '/app/customers' : '/app/catalog'}
        >
          {kind === 'customers' ? 'Open customers' : 'Open the catalog'}
        </Link>
        <Button variant="secondary" size="sm" onClick={onAgain}>
          Import another file
        </Button>
      </div>
    </div>
  );
}

function RecentImports() {
  const { timezone } = useShop();
  const query = useImportBatches();
  const columns: Column<ImportBatch>[] = [
    {
      key: 'file',
      header: 'File',
      primary: true,
      cell: (b) => (
        <span className="flex flex-col">
          <span className="truncate">{b.file_name ?? 'Import'}</span>
          <span className="text-muted text-xs">
            {b.kind === 'customers' ? KIND_LABELS.customers : KIND_LABELS.services}
          </span>
        </span>
      ),
    },
    { key: 'when', header: 'When', cell: (b) => formatDateTime(b.created_at, timezone) },
    {
      key: 'result',
      header: 'Result',
      cell: (b) => (
        <span className="text-sm">
          {b.created_count} new · {b.updated_count} updated · {b.skipped_count} unchanged
          {b.error_count > 0 && (
            <span className="text-danger-ink"> · {b.error_count} problems</span>
          )}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      cell: (b) => (
        <Badge tone={b.status === 'failed' ? 'danger' : 'success'}>
          {b.status === 'failed' ? 'Nothing imported' : 'Done'}
        </Badge>
      ),
    },
  ];
  return (
    <SectionCard title="Recent imports" flush>
      <QueryView query={query} label="recent imports">
        {(rows) =>
          rows.length === 0 ? (
            <EmptyState compact title="No imports yet" />
          ) : (
            <Table caption="Recent imports" columns={columns} rows={rows} getRowId={(b) => b.id} />
          )
        }
      </QueryView>
    </SectionCard>
  );
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

function yesNo(value: boolean): string {
  return value ? 'yes' : 'no';
}

function ExportCard() {
  const { shop, shopId, timezone } = useShop();
  const toast = useToast();
  const customerFields = useCustomFields('customer');
  const today = shopToday(timezone);
  const [from, setFrom] = useState(addLocalDays(today, -90));
  const [to, setTo] = useState(today);
  const [busy, setBusy] = useState<'customers' | 'vehicles' | 'jobs' | null>(null);
  const stem = fileStem(shop.name, 'shop');
  const rangeProblem =
    !isLocalDate(from) || !isLocalDate(to)
      ? 'Choose both dates.'
      : to < from
        ? 'The end date must be on or after the start date.'
        : localDaysBetween(from, to) > 366 * 3
          ? 'Export at most 3 years at a time.'
          : null;

  const exportCustomers = async () => {
    setBusy('customers');
    try {
      const rows = await fetchExportCustomers(shopId);
      const fields = (customerFields.data ?? []).filter((f) => !f.archived_at);
      const columns: CsvColumn<ExportCustomer>[] = [
        { header: 'First name', value: (c) => c.first_name },
        { header: 'Last name', value: (c) => c.last_name },
        { header: 'Company', value: (c) => c.company },
        { header: 'Email', value: (c) => c.email },
        { header: 'Phone', value: (c) => c.phone },
        { header: 'Address line 1', value: (c) => c.address_line1 },
        { header: 'Address line 2', value: (c) => c.address_line2 },
        { header: 'City', value: (c) => c.city },
        { header: 'Region', value: (c) => c.region },
        { header: 'Postal code', value: (c) => c.postal_code },
        { header: 'Country', value: (c) => c.country },
        { header: 'Tags', value: (c) => c.tags.join('; ') },
        { header: 'Lifecycle', value: (c) => c.lifecycle },
        { header: 'Source', value: (c) => c.source },
        { header: 'SMS opt in', value: (c) => yesNo(c.sms_opt_in) },
        { header: 'Email opt in', value: (c) => yesNo(c.email_opt_in) },
        { header: 'Notes', value: (c) => c.notes },
        ...fields.map<CsvColumn<ExportCustomer>>((f) => ({
          header: f.label,
          value: (c) => {
            const value = readCustomData(c.custom_data)[f.key];
            return Array.isArray(value)
              ? value.join('; ')
              : value === undefined
                ? ''
                : String(value);
          },
        })),
        { header: 'Created', value: (c) => formatInTz(c.created_at, timezone, 'yyyy-MM-dd HH:mm') },
      ];
      downloadCsv(`${stem}-customers-${today}.csv`, toCsv(columns, rows));
      toast.success(`${rows.length.toLocaleString('en-US')} customers exported`);
    } catch (error) {
      toast.error(error);
    } finally {
      setBusy(null);
    }
  };

  const exportVehicles = async () => {
    setBusy('vehicles');
    try {
      const rows = await fetchExportVehicles(shopId);
      const columns: CsvColumn<ExportVehicle>[] = [
        { header: 'First name', value: (v) => v.customer?.first_name },
        { header: 'Last name', value: (v) => v.customer?.last_name },
        { header: 'Company', value: (v) => v.customer?.company },
        { header: 'Email', value: (v) => v.customer?.email },
        { header: 'Phone', value: (v) => v.customer?.phone },
        { header: 'Year', value: (v) => v.year },
        { header: 'Make', value: (v) => v.make },
        { header: 'Model', value: (v) => v.model },
        { header: 'Trim', value: (v) => v.trim },
        { header: 'Color', value: (v) => v.color },
        { header: 'License plate', value: (v) => v.license_plate },
        { header: 'VIN', value: (v) => v.vin },
        { header: 'Vehicle size', value: (v) => v.category?.name },
      ];
      downloadCsv(`${stem}-vehicles-${today}.csv`, toCsv(columns, rows));
      toast.success(`${rows.length.toLocaleString('en-US')} vehicles exported`);
    } catch (error) {
      toast.error(error);
    } finally {
      setBusy(null);
    }
  };

  const exportJobs = async () => {
    if (rangeProblem) return;
    setBusy('jobs');
    try {
      const rows = await fetchExportJobs(shopId, from, to);
      type Job = (typeof rows)[number];
      const columns: CsvColumn<Job>[] = [
        { header: 'Job', value: (j) => j.number },
        { header: 'Status', value: (j) => j.status },
        { header: 'Scheduled', value: (j) => j.scheduled_local },
        { header: 'Completed', value: (j) => j.completed_local },
        { header: 'Customer', value: (j) => j.customer_name },
        { header: 'Email', value: (j) => j.customer_email },
        { header: 'Phone', value: (j) => j.customer_phone },
        { header: 'Vehicle', value: (j) => j.vehicle },
        { header: 'Services', value: (j) => j.services },
        { header: 'Location', value: (j) => j.location_type },
        { header: 'Service address', value: (j) => j.service_address },
        { header: 'Source', value: (j) => j.source },
        { header: 'Total', value: (j) => centsCell(j.total_cents) },
        { header: 'Paid', value: (j) => centsCell(j.paid_cents) },
        { header: 'Balance', value: (j) => centsCell(j.balance_cents) },
      ];
      downloadCsv(`${stem}-jobs-${from}-to-${to}.csv`, toCsv(columns, rows));
      toast.success(`${rows.length.toLocaleString('en-US')} jobs exported`);
    } catch (error) {
      toast.error(error);
    } finally {
      setBusy(null);
    }
  };

  return (
    <SectionCard
      title="Export"
      description="Download your data as CSV files for Excel, Google Sheets or your accountant. Amounts are in dollars and cents; dates are in your shop’s time zone."
    >
      <div className="flex flex-col gap-5">
        <div className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            leadingIcon={<Download className="size-4" aria-hidden="true" />}
            loading={busy === 'customers'}
            disabled={busy !== null}
            onClick={() => void exportCustomers()}
          >
            Customers
          </Button>
          <Button
            variant="secondary"
            leadingIcon={<Download className="size-4" aria-hidden="true" />}
            loading={busy === 'vehicles'}
            disabled={busy !== null}
            onClick={() => void exportVehicles()}
          >
            Vehicles
          </Button>
        </div>
        <fieldset className="flex flex-col gap-2">
          <legend className="text-ink mb-1 text-sm font-medium">Jobs</legend>
          <div className="flex flex-wrap items-end gap-3">
            <FormField label="From" className="w-44">
              <DateInput value={from} onChange={(e) => setFrom(e.target.value)} />
            </FormField>
            <FormField label="To" className="w-44">
              <DateInput value={to} onChange={(e) => setTo(e.target.value)} />
            </FormField>
            <Button
              variant="secondary"
              leadingIcon={<Download className="size-4" aria-hidden="true" />}
              loading={busy === 'jobs'}
              disabled={busy !== null || rangeProblem !== null}
              onClick={() => void exportJobs()}
            >
              Jobs
            </Button>
          </div>
          {rangeProblem ? (
            <p role="alert" className="text-danger-ink text-xs font-medium">
              {rangeProblem}
            </p>
          ) : (
            <p className="text-muted text-xs">
              Jobs scheduled (or created, if not scheduled) in these dates, with totals and what was
              paid.
            </p>
          )}
        </fieldset>
      </div>
    </SectionCard>
  );
}
