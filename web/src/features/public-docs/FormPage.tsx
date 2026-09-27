import { PenLine } from 'lucide-react';
import { useRef, useState, type FormEvent } from 'react';
import { useParams } from 'react-router';
import { PublicLayout } from '@/components/layout/PublicLayout';
import {
  Button,
  FormField,
  Input,
  SectionCard,
  SignaturePad,
  type SignaturePadHandle,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { errorMessage } from '@/lib/errors';
import { usePublicForm, useSignForm, type FormDocument } from './api';
import { personName } from './shared/format';
import { Banner, DocumentTitle, PublicError, PublicLoading } from './shared/PublicPage';
import { SafeMarkdown } from './shared/SafeMarkdown';
import { isLinkToken, toBranding } from './shared/schemas';

export default function FormPage() {
  const { token } = useParams();
  if (!isLinkToken(token)) return <PublicError error={null} what="form" />;
  return <FormView token={token} />;
}

function FormView({ token }: { token: string }) {
  const query = usePublicForm(token);
  if (query.isPending) return <PublicLoading label="Loading form…" />;
  if (query.isError) {
    return (
      <PublicError
        error={query.error}
        what="form"
        onRetry={() => void query.refetch()}
        retrying={query.isFetching}
      />
    );
  }
  return <FormDocumentView token={token} doc={query.data} />;
}

function FormDocumentView({ token, doc }: { token: string; doc: FormDocument }) {
  const { shop, form, job } = doc;
  const tz = shop.timezone;
  return (
    <PublicLayout shop={toBranding(shop)}>
      <div className="flex flex-col gap-4 sm:gap-5">
        <DocumentTitle
          title={form.title}
          subtitle={[
            job ? `Appointment #${job.number}` : null,
            job?.scheduled_start ? formatDateTime(job.scheduled_start, tz) : null,
            job?.vehicle,
          ]
            .filter(Boolean)
            .join(' · ')}
        />

        {form.status === 'signed' && (
          <Banner tone="success" title="Signed — thank you!">
            {form.signer_name ? `Signed by ${form.signer_name}` : 'Signed'}
            {form.signed_at ? ` on ${formatDateTime(form.signed_at, tz)}` : ''}.
          </Banner>
        )}
        {form.status === 'void' && (
          <Banner tone="warning" title="This form is no longer needed">
            The appointment it belongs to was cancelled, so it can’t be signed.
          </Banner>
        )}

        <SectionCard title="Document">
          <SafeMarkdown source={form.body} />
        </SectionCard>

        {form.status === 'pending' && (
          <SignPanel
            token={token}
            requiresSignature={form.requires_signature}
            uploadPrefix={doc.signature_upload_prefix}
            suggestedName={personName(doc.customer)}
          />
        )}
      </div>
    </PublicLayout>
  );
}

function SignPanel({
  token,
  requiresSignature,
  uploadPrefix,
  suggestedName,
}: {
  token: string;
  requiresSignature: boolean;
  uploadPrefix: string | null;
  suggestedName: string | null;
}) {
  const sign = useSignForm(token);
  const padRef = useRef<SignaturePadHandle>(null);
  const [name, setName] = useState(suggestedName ?? '');
  const [nameError, setNameError] = useState<string | null>(null);
  const [signatureError, setSignatureError] = useState<string | null>(null);
  const [hasSignature, setHasSignature] = useState(false);

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
    } else {
      setNameError(null);
    }
    const pad = padRef.current;
    if (requiresSignature && (!pad || pad.isEmpty())) {
      setSignatureError('Draw your signature in the box.');
      ok = false;
    } else {
      setSignatureError(null);
    }
    if (!ok) return;
    const signature = requiresSignature && pad ? await pad.toBlob() : null;
    if (requiresSignature && !signature) {
      setSignatureError('Your signature could not be read. Clear it and sign again.');
      return;
    }
    sign.mutate({ signerName: signer, signature, uploadPrefix });
  };

  return (
    <SectionCard
      title={requiresSignature ? 'Sign this form' : 'Acknowledge this form'}
      description={
        requiresSignature
          ? 'Type your name and draw your signature to agree.'
          : 'Type your name to confirm you have read and agree to this form.'
      }
    >
      <form noValidate onSubmit={(event) => void submit(event)} className="flex flex-col gap-4">
        {sign.isError && (
          <Banner tone="danger" title="Couldn’t sign the form">
            {errorMessage(sign.error)}
          </Banner>
        )}
        <FormField label="Your full name" required error={nameError}>
          <Input
            value={name}
            onChange={(event) => setName(event.target.value)}
            autoComplete="name"
            maxLength={200}
            inputSize="lg"
          />
        </FormField>
        {requiresSignature && (
          <div className="flex flex-col gap-1.5">
            <p className="text-ink text-sm font-medium" id="signature-label">
              Signature
              <span className="text-danger-ink ml-0.5" aria-hidden="true">
                *
              </span>
            </p>
            <SignaturePad
              ref={padRef}
              label="Your signature"
              onChange={(signed) => {
                setHasSignature(signed);
                if (signed) setSignatureError(null);
              }}
              disabled={sign.isPending}
            />
            {signatureError && (
              <p role="alert" className="text-danger-ink text-xs font-medium">
                {signatureError}
              </p>
            )}
          </div>
        )}
        <Button
          type="submit"
          size="lg"
          loading={sign.isPending}
          leadingIcon={<PenLine className="size-4" aria-hidden="true" />}
          className="sm:self-end"
          aria-describedby={requiresSignature && !hasSignature ? 'signature-label' : undefined}
        >
          {requiresSignature ? 'Sign form' : 'I agree'}
        </Button>
      </form>
    </SectionCard>
  );
}
