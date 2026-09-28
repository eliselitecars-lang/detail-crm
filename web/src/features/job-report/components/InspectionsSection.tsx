import { ImageIcon, PenLine } from 'lucide-react';
import { useRef, useState, type FormEvent } from 'react';
import {
  Badge,
  Button,
  FormField,
  Input,
  SectionCard,
  SignaturePad,
  type SignaturePadHandle,
} from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { VehicleDiagram } from '@/features/jobs/components/detail/VehicleDiagram';
import { DAMAGE_LABELS, VIEW_LABELS } from '@/features/jobs/model';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { useAcknowledgeInspection, type JobReport, type ReportInspection } from '../api';
import { mediaKey } from '../media';
import { marksByView } from '../model';

const TITLES: Record<ReportInspection['kind'], string> = {
  pre: 'Condition before the service',
  post: 'Condition after the service',
};

/** Read-only damage diagrams, plus the remote sign-off of the pre-service inspection. */
export function InspectionsSection({
  token,
  report,
  urls,
}: {
  token: string;
  report: JobReport;
  urls: ReadonlyMap<string, string>;
}) {
  return (
    <>
      {report.inspections.map((inspection) => (
        <InspectionCard
          key={inspection.id}
          token={token}
          inspection={inspection}
          uploadPrefix={report.signature_upload_prefix}
          urls={urls}
        />
      ))}
    </>
  );
}

function InspectionCard({
  token,
  inspection,
  uploadPrefix,
  urls,
}: {
  token: string;
  inspection: ReportInspection;
  uploadPrefix: string | null;
  urls: ReadonlyMap<string, string>;
}) {
  const groups = marksByView(inspection.marks);
  const details = [
    inspection.mileage !== null ? `Mileage ${inspection.mileage.toLocaleString('en-US')}` : null,
    inspection.fuel_level !== null ? `Fuel ${inspection.fuel_level}%` : null,
  ].filter(Boolean);

  return (
    <SectionCard
      title={TITLES[inspection.kind]}
      description={details.length > 0 ? details.join(' · ') : undefined}
      actions={
        inspection.signed_at ? (
          <Badge tone="success">
            Signed{inspection.signed_by_name ? ` by ${inspection.signed_by_name}` : ''}
          </Badge>
        ) : undefined
      }
    >
      <div className="flex flex-col gap-4">
        {groups.length === 0 ? (
          <p className="text-muted text-sm">No damage was marked.</p>
        ) : (
          groups.map((group) => (
            <section
              key={group.view}
              className="flex flex-col gap-2"
              aria-label={VIEW_LABELS[group.view]}
            >
              <h4 className="text-ink text-sm font-medium">{VIEW_LABELS[group.view]}</h4>
              <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
                <VehicleDiagram
                  view={group.view}
                  marks={group.marks.map((m) => ({ id: m.id, x: m.x, y: m.y, number: m.number }))}
                />
                <ol className="flex flex-col gap-2" aria-label={`${VIEW_LABELS[group.view]} marks`}>
                  {group.marks.map((mark) => {
                    const photo = mark.has_photo
                      ? urls.get(mediaKey('mark_photo', mark.id))
                      : undefined;
                    return (
                      <li key={mark.id} className="flex items-start gap-2 text-sm">
                        <span className="bg-danger text-primary-fg flex size-5 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold">
                          {mark.number}
                        </span>
                        <div className="min-w-0 flex-1">
                          <p className="text-ink font-medium">{DAMAGE_LABELS[mark.damage]}</p>
                          {mark.note && <p className="text-muted break-words">{mark.note}</p>}
                        </div>
                        {photo && (
                          <a
                            href={photo}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="text-primary-ink inline-flex shrink-0 items-center gap-1 text-xs font-medium hover:underline"
                          >
                            <ImageIcon className="size-3.5" aria-hidden="true" />
                            Photo<span className="sr-only"> of mark {mark.number} (new tab)</span>
                          </a>
                        )}
                      </li>
                    );
                  })}
                </ol>
              </div>
            </section>
          ))
        )}
        {inspection.can_acknowledge && uploadPrefix && (
          <SignOffPanel token={token} inspectionId={inspection.id} uploadPrefix={uploadPrefix} />
        )}
      </div>
    </SectionCard>
  );
}

function SignOffPanel({
  token,
  inspectionId,
  uploadPrefix,
}: {
  token: string;
  inspectionId: string;
  uploadPrefix: string;
}) {
  const ack = useAcknowledgeInspection(token);
  const padRef = useRef<SignaturePadHandle>(null);
  const [name, setName] = useState('');
  const [nameError, setNameError] = useState<string | null>(null);
  const [signatureError, setSignatureError] = useState<string | null>(null);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const signer = name.trim();
    let ok = true;
    if (!signer) {
      setNameError('Type your full name.');
      ok = false;
    } else if (signer.length > 200) {
      setNameError('Name must be 200 characters or fewer.');
      ok = false;
    } else setNameError(null);
    const pad = padRef.current;
    if (!pad || pad.isEmpty()) {
      setSignatureError('Draw your signature in the box.');
      ok = false;
    } else setSignatureError(null);
    if (!ok || !pad) return;
    const signature = await pad.toBlob();
    if (!signature) {
      setSignatureError('Your signature could not be read. Clear it and sign again.');
      return;
    }
    ack.mutate({ inspectionId, signerName: signer, signature, uploadPrefix });
  };

  return (
    <form
      noValidate
      onSubmit={(event) => void submit(event)}
      className="border-line flex flex-col gap-4 border-t pt-4"
      aria-labelledby="signoff-title"
    >
      <div>
        <h4 id="signoff-title" className="text-ink text-sm font-semibold">
          Review and sign
        </h4>
        <p className="text-muted text-sm">
          By signing you confirm the vehicle’s condition shown above before the work started.
        </p>
      </div>
      {ack.isError && (
        <Banner tone="danger" title="Couldn’t save your signature">
          {errorMessage(ack.error)}
        </Banner>
      )}
      <FormField label="Your full name" required error={nameError}>
        <Input
          value={name}
          onChange={(e) => setName(e.target.value)}
          autoComplete="name"
          maxLength={200}
        />
      </FormField>
      <div className="flex flex-col gap-1.5">
        <p className="text-ink text-sm font-medium">
          Signature
          <span className="text-danger-ink ml-0.5" aria-hidden="true">
            *
          </span>
        </p>
        <SignaturePad
          ref={padRef}
          label="Your signature"
          onChange={(signed) => {
            if (signed) setSignatureError(null);
          }}
          disabled={ack.isPending}
        />
        {signatureError && (
          <p role="alert" className="text-danger-ink text-xs font-medium">
            {signatureError}
          </p>
        )}
      </div>
      <Button
        type="submit"
        loading={ack.isPending}
        leadingIcon={<PenLine className="size-4" aria-hidden="true" />}
        className="sm:self-end"
      >
        Sign inspection
      </Button>
    </form>
  );
}
