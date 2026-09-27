import { ClipboardCheck, Lock, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  ConfirmDialog,
  Dialog,
  EmptyState,
  ErrorState,
  FormField,
  IconButton,
  Input,
  LoadingState,
  SectionCard,
  Select,
  Tabs,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import type { JobDetail } from '../../api';
import {
  useAddMark,
  useClearInspectionSignature,
  useCreateInspection,
  useDeleteInspection,
  useDeleteMark,
  useInspections,
  useSignInspection,
  useUpdateInspection,
  type Inspection,
} from '../../fieldApi';
import {
  customerName,
  DAMAGE_KINDS,
  DAMAGE_LABELS,
  PHOTO_MIME_TYPES,
  photoProblem,
  VEHICLE_VIEWS,
  VIEW_LABELS,
  type DamageKind,
  type InspectionKind,
  type VehicleView,
} from '../../model';
import { SignatureDialog } from './SignatureDialog';
import { VehicleDiagram } from './VehicleDiagram';

const KIND_LABEL: Record<InspectionKind, string> = {
  pre: 'Pre-service inspection',
  post: 'Post-service inspection',
};

export function InspectionsCard({ job }: { job: JobDetail }) {
  const toast = useToast();
  const inspections = useInspections(job.id);
  const create = useCreateInspection(job.id);
  const rows = inspections.data ?? [];
  const missing = (['pre', 'post'] as const).filter((k) => !rows.some((r) => r.kind === k));

  const start = async (kind: InspectionKind) => {
    try {
      await create.mutateAsync({ kind, vehicleId: job.vehicle_id });
      toast.success(`${KIND_LABEL[kind]} started`);
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard
      title="Inspections"
      description="Record existing damage with the customer before and after the work."
      actions={
        missing.length > 0 && !inspections.isPending ? (
          <div className="flex flex-wrap gap-2">
            {missing.map((kind) => (
              <Button
                key={kind}
                size="sm"
                variant="secondary"
                loading={create.isPending && create.variables.kind === kind}
                leadingIcon={<ClipboardCheck className="size-4" aria-hidden="true" />}
                onClick={() => void start(kind)}
              >
                {kind === 'pre' ? 'Start pre' : 'Start post'}
              </Button>
            ))}
          </div>
        ) : undefined
      }
    >
      {inspections.isPending ? (
        <LoadingState label="Loading inspections…" />
      ) : inspections.isError ? (
        <ErrorState compact error={inspections.error} onRetry={() => void inspections.refetch()} />
      ) : rows.length === 0 ? (
        <EmptyState compact title="No inspections yet" />
      ) : (
        <div className="flex flex-col gap-6">
          {rows.map((inspection) => (
            <InspectionPanel key={inspection.id} job={job} inspection={inspection} />
          ))}
        </div>
      )}
    </SectionCard>
  );
}

function InspectionPanel({ job, inspection }: { job: JobDetail; inspection: Inspection }) {
  const { timezone } = useShop();
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const [view, setView] = useState<VehicleView>('front');
  const [pending, setPending] = useState<{ x: number; y: number } | null>(null);
  const [signing, setSigning] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const addMark = useAddMark(job.id);
  const deleteMark = useDeleteMark(job.id);
  const update = useUpdateInspection(job.id);
  const sign = useSignInspection(job.id);
  const clear = useClearInspectionSignature(job.id);
  const remove = useDeleteInspection(job.id);
  const locked = inspection.signed_at !== null;
  const numbered = inspection.marks.map((m, i) => ({ ...m, number: i + 1 }));
  const inView = numbered.filter((m) => m.view === view);

  const [mileage, setMileage] = useState(inspection.mileage?.toString() ?? '');
  const [fuel, setFuel] = useState(inspection.fuel_level?.toString() ?? '');
  const [notes, setNotes] = useState(inspection.notes ?? '');
  const [detailsError, setDetailsError] = useState<string | null>(null);

  const saveDetails = async () => {
    setDetailsError(null);
    const m = mileage.trim() === '' ? null : Number(mileage);
    const f = fuel.trim() === '' ? null : Number(fuel);
    if (m !== null && (!Number.isInteger(m) || m < 0 || m > 9_999_999)) {
      setDetailsError('Mileage must be a whole number.');
      return;
    }
    if (f !== null && (!Number.isInteger(f) || f < 0 || f > 100)) {
      setDetailsError('Fuel level is a percentage from 0 to 100.');
      return;
    }
    try {
      await update.mutateAsync({
        id: inspection.id,
        patch: { mileage: m, fuel_level: f, notes: notes.trim() || null },
      });
      toast.success('Inspection saved');
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <section aria-labelledby={`insp-${inspection.id}`} className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h4 id={`insp-${inspection.id}`} className="text-ink flex items-center gap-2 font-semibold">
          {KIND_LABEL[inspection.kind]}
          {locked ? (
            <Badge tone="success">
              <Lock className="size-3" aria-hidden="true" />
              Signed
            </Badge>
          ) : (
            <Badge tone="warning">Awaiting signature</Badge>
          )}
        </h4>
        {!locked && (
          <Button size="sm" variant="ghost" onClick={() => setConfirmDelete(true)}>
            Delete
          </Button>
        )}
      </div>

      <Tabs
        label={`${KIND_LABEL[inspection.kind]} views`}
        value={view}
        onChange={setView}
        items={VEHICLE_VIEWS.map((v) => ({
          value: v,
          label: VIEW_LABELS[v],
          count: numbered.filter((m) => m.view === v).length || undefined,
        }))}
      />
      <VehicleDiagram
        view={view}
        marks={inView}
        {...(locked ? {} : { onAdd: (x: number, y: number) => setPending({ x, y }) })}
        className="max-w-xl"
      />
      {inView.length > 0 && (
        <ol className="flex flex-col gap-2">
          {inView.map((m) => (
            <li key={m.id} className="flex items-start gap-3 text-sm">
              <span className="bg-danger flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold text-white">
                {m.number}
              </span>
              <div className="min-w-0 flex-1">
                <p className="text-ink font-medium">{DAMAGE_LABELS[m.damage]}</p>
                {m.note && <p className="text-muted">{m.note}</p>}
                {m.photoUrl && (
                  <a
                    href={m.photoUrl}
                    target="_blank"
                    rel="noreferrer"
                    className="text-primary-ink text-xs hover:underline"
                  >
                    View photo
                  </a>
                )}
              </div>
              {!locked && (
                <IconButton
                  size="sm"
                  variant="danger"
                  label={`Remove mark ${m.number}`}
                  icon={<Trash2 className="size-4" />}
                  onClick={() =>
                    deleteMark.mutateAsync(m).catch((error: unknown) => toast.error(error))
                  }
                />
              )}
            </li>
          ))}
        </ol>
      )}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <FormField label="Mileage">
          <Input
            inputMode="numeric"
            value={mileage}
            disabled={locked}
            onChange={(e) => setMileage(e.target.value)}
          />
        </FormField>
        <FormField label="Fuel level (%)">
          <Input
            inputMode="numeric"
            value={fuel}
            disabled={locked}
            onChange={(e) => setFuel(e.target.value)}
          />
        </FormField>
        <FormField label="Notes" className="sm:col-span-2">
          <Textarea
            rows={2}
            maxLength={20000}
            value={notes}
            disabled={locked}
            onChange={(e) => setNotes(e.target.value)}
          />
        </FormField>
      </div>
      {detailsError && (
        <p role="alert" className="text-danger-ink text-sm">
          {detailsError}
        </p>
      )}

      <div className="flex flex-wrap items-center gap-3">
        {!locked && (
          <>
            <Button
              size="sm"
              variant="secondary"
              loading={update.isPending}
              onClick={() => void saveDetails()}
            >
              Save details
            </Button>
            <Button size="sm" onClick={() => setSigning(true)}>
              Collect customer signature
            </Button>
          </>
        )}
        {locked && (
          <div className="flex flex-wrap items-center gap-3">
            {inspection.signatureUrl && (
              <img
                src={inspection.signatureUrl}
                alt={`Signature of ${inspection.signed_by_name ?? 'the customer'}`}
                className="border-line bg-surface h-16 rounded-control border"
              />
            )}
            <p className="text-muted text-sm">
              Signed by {inspection.signed_by_name}
              {inspection.signed_at ? ` · ${formatDateTime(inspection.signed_at, timezone)}` : ''}
            </p>
            {canManage && (
              <Button
                size="sm"
                variant="ghost"
                loading={clear.isPending}
                onClick={() =>
                  clear
                    .mutateAsync(inspection.id)
                    .then(() => toast.success('Signature removed; the inspection can be edited'))
                    .catch((error: unknown) => toast.error(error))
                }
              >
                Remove signature
              </Button>
            )}
          </div>
        )}
      </div>

      {pending && (
        <MarkDialog
          view={view}
          pending={addMark.isPending}
          onClose={() => setPending(null)}
          onSave={async (damage, note, photo) => {
            try {
              await addMark.mutateAsync({
                inspectionId: inspection.id,
                view,
                x: pending.x,
                y: pending.y,
                damage,
                note,
                photo,
              });
              setPending(null);
            } catch (error) {
              toast.error(error);
            }
          }}
        />
      )}
      {signing && (
        <SignatureDialog
          title={`Sign the ${KIND_LABEL[inspection.kind].toLowerCase()}`}
          description="The customer confirms the recorded vehicle condition. The inspection locks once signed."
          requireDrawing
          defaultName={job.customer ? customerName(job.customer) : ''}
          pending={sign.isPending}
          onClose={() => setSigning(false)}
          onSign={async (signerName, signature) => {
            if (!signature) return;
            try {
              await sign.mutateAsync({ inspectionId: inspection.id, signerName, signature });
              toast.success('Inspection signed');
              setSigning(false);
            } catch (error) {
              toast.error(error);
            }
          }}
        >
          <p className="text-muted text-sm">
            {inspection.marks.length === 0
              ? 'No damage was recorded.'
              : `${inspection.marks.length} damage mark${inspection.marks.length === 1 ? '' : 's'} recorded.`}
          </p>
        </SignatureDialog>
      )}
      <ConfirmDialog
        open={confirmDelete}
        onClose={() => setConfirmDelete(false)}
        tone="danger"
        title="Delete this inspection?"
        description="Its damage marks are deleted too."
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          try {
            await remove.mutateAsync(inspection.id);
            toast.success('Inspection deleted');
            setConfirmDelete(false);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </section>
  );
}

interface MarkDialogProps {
  view: VehicleView;
  pending: boolean;
  onClose: () => void;
  onSave: (damage: DamageKind, note: string | null, photo: File | null) => Promise<void>;
}

function MarkDialog({ view, pending, onClose, onSave }: MarkDialogProps) {
  const [damage, setDamage] = useState<DamageKind>('scratch');
  const [note, setNote] = useState('');
  const [photo, setPhoto] = useState<File | null>(null);
  const [error, setError] = useState<string | null>(null);

  return (
    <Dialog
      open
      onClose={onClose}
      title={`Add damage — ${VIEW_LABELS[view]}`}
      size="sm"
      dismissible={!pending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={pending}>
            Cancel
          </Button>
          <Button loading={pending} onClick={() => void onSave(damage, note.trim() || null, photo)}>
            Add mark
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        <FormField label="Damage">
          <Select
            value={damage}
            onChange={(e) => {
              const next = DAMAGE_KINDS.find((k) => k === e.target.value);
              if (next) setDamage(next);
            }}
            options={DAMAGE_KINDS.map((k) => ({ value: k, label: DAMAGE_LABELS[k] }))}
          />
        </FormField>
        <FormField label="Note" help="Describe the exact spot if you used the keyboard.">
          <Textarea rows={2} maxLength={2000} value={note} onChange={(e) => setNote(e.target.value)} />
        </FormField>
        <FormField label="Photo" help="Optional." error={error}>
          <Input
            type="file"
            accept={PHOTO_MIME_TYPES.join(',')}
            onChange={(e) => {
              const file = e.target.files?.[0] ?? null;
              const problem = file ? photoProblem(file) : null;
              setError(problem);
              setPhoto(problem ? null : file);
            }}
          />
        </FormField>
      </div>
    </Dialog>
  );
}
