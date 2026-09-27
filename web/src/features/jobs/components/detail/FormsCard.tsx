import { Copy, FileSignature, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  IconButton,
  LoadingState,
  SectionCard,
  Select,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import type { JobDetail } from '../../api';
import {
  useAttachForm,
  useDeleteForm,
  useFormTemplates,
  useForms,
  useSignForm,
  type FormSubmission,
} from '../../fieldApi';
import { customerName, formLink } from '../../model';
import { SignatureDialog } from './SignatureDialog';

export function FormsCard({ job }: { job: JobDetail }) {
  const { timezone } = useShop();
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const forms = useForms(job.id);
  const templates = useFormTemplates(canManage);
  const attach = useAttachForm(job.id);
  const remove = useDeleteForm(job.id);
  const sign = useSignForm(job.id);
  const [templateId, setTemplateId] = useState('');
  const [signing, setSigning] = useState<FormSubmission | null>(null);
  const [deleting, setDeleting] = useState<FormSubmission | null>(null);
  const voided = job.status === 'cancelled' || job.status === 'no_show';

  const rows = forms.data ?? [];
  const attachable = (templates.data ?? []).filter(
    (t) => !rows.some((r) => r.form_template_id === t.id),
  );

  const copyLink = async (form: FormSubmission) => {
    const link = formLink(window.location.origin, form.public_token);
    try {
      await navigator.clipboard.writeText(link);
      toast.success('Form link copied', link);
    } catch {
      toast.info('Copy this link', link);
    }
  };

  const onAttach = async () => {
    const template = attachable.find((t) => t.id === templateId);
    if (!template) return;
    try {
      await attach.mutateAsync(template);
      toast.success('Form added');
      setTemplateId('');
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <SectionCard title="Forms" description="Waivers and agreements for this job.">
      {forms.isPending ? (
        <LoadingState label="Loading forms…" />
      ) : forms.isError ? (
        <ErrorState compact error={forms.error} onRetry={() => void forms.refetch()} />
      ) : rows.length === 0 ? (
        <EmptyState compact title="No forms on this job" />
      ) : (
        <ul className="divide-line -my-2 divide-y">
          {rows.map((form) => (
            <li key={form.id} className="flex flex-wrap items-center gap-x-3 gap-y-2 py-3">
              <div className="min-w-0 flex-1">
                <p className="text-ink font-medium">{form.title}</p>
                <p className="text-muted text-xs">
                  {form.signed_at
                    ? `Signed by ${form.signer_name ?? 'customer'} · ${formatDateTime(form.signed_at, timezone)}`
                    : voided
                      ? 'Void — the job was cancelled'
                      : form.requires_signature
                        ? 'Waiting for a signature'
                        : 'Waiting for acknowledgement'}
                </p>
              </div>
              {form.signed_at ? (
                <Badge tone="success">Signed</Badge>
              ) : voided ? (
                <Badge>Void</Badge>
              ) : (
                <div className="flex flex-wrap items-center gap-1.5">
                  <Button
                    size="sm"
                    variant="ghost"
                    leadingIcon={<Copy className="size-4" aria-hidden="true" />}
                    onClick={() => void copyLink(form)}
                  >
                    Copy link
                  </Button>
                  <Button
                    size="sm"
                    variant="secondary"
                    leadingIcon={<FileSignature className="size-4" aria-hidden="true" />}
                    onClick={() => setSigning(form)}
                  >
                    Sign here
                  </Button>
                  {canManage && (
                    <IconButton
                      size="sm"
                      variant="danger"
                      label={`Remove ${form.title}`}
                      icon={<Trash2 className="size-4" />}
                      onClick={() => setDeleting(form)}
                    />
                  )}
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      {canManage && attachable.length > 0 && (
        <div className="border-line mt-4 flex gap-2 border-t pt-4">
          <Select
            aria-label="Form template"
            value={templateId}
            onChange={(e) => setTemplateId(e.target.value)}
            placeholder="Add a form…"
            options={attachable.map((t) => ({ value: t.id, label: t.name }))}
          />
          <Button
            variant="secondary"
            loading={attach.isPending}
            disabled={!templateId}
            onClick={() => void onAttach()}
          >
            Add
          </Button>
        </div>
      )}
      {signing && (
        <SignatureDialog
          title={signing.title}
          requireDrawing={signing.requires_signature}
          defaultName={job.customer ? customerName(job.customer) : ''}
          pending={sign.isPending}
          onClose={() => setSigning(null)}
          onSign={async (signerName, signature) => {
            try {
              await sign.mutateAsync({ submissionId: signing.id, signerName, signature });
              toast.success('Form signed');
              setSigning(null);
            } catch (error) {
              toast.error(error);
            }
          }}
        >
          <div className="border-line bg-surface-2 text-ink rounded-control border p-3 text-sm whitespace-pre-wrap">
            {signing.body_snapshot}
          </div>
        </SignatureDialog>
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title="Remove this form?"
        description="The customer’s link stops working."
        confirmLabel="Remove"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Form removed');
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}
