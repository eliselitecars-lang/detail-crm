import { FileText, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  FileDropzone,
  formatBytes,
  IconButton,
  LoadingState,
  SectionCard,
  Switch,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useAuth } from '@/features/auth/authContext';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import {
  DOCUMENT_ACCEPT,
  DOCUMENT_FORMATS_TEXT,
  DOCUMENT_MAX_BYTES,
  documentKindLabel,
  documentProblem,
} from '../../documents';
import {
  useDeleteJobDocument,
  useJobDocuments,
  useSetDocumentVisible,
  useUploadJobDocument,
  type JobDocument,
} from '../../documentsApi';

const MAX_FILES = 10;

/**
 * Files on the job (P-25): PDFs, Word / Excel files, text and images.
 * Managers choose which ones the customer sees (job report, booking page,
 * portal); technicians add files and delete their own.
 */
export function DocumentsCard({ jobId }: { jobId: string }) {
  const { timezone } = useShop();
  const { user } = useAuth();
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const documents = useJobDocuments(jobId);
  const upload = useUploadJobDocument(jobId);
  const setVisible = useSetDocumentVisible(jobId);
  const remove = useDeleteJobDocument(jobId);
  const [uploading, setUploading] = useState(false);
  const [deleting, setDeleting] = useState<JobDocument | null>(null);

  const onFiles = async (files: File[]) => {
    setUploading(true);
    let ok = 0;
    for (const file of files) {
      const problem = documentProblem(file);
      if (problem) {
        toast.error(`${file.name}: ${problem}`);
        continue;
      }
      try {
        await upload.mutateAsync(file);
        ok += 1;
      } catch (error) {
        toast.error(error, file.name);
      }
    }
    setUploading(false);
    if (ok > 0) toast.success(ok === 1 ? 'File added' : `${ok} files added`);
  };

  const rows = documents.data ?? [];

  return (
    <SectionCard
      title="Files"
      description="Contracts, spec sheets, warranty cards and other files."
    >
      <div className="flex flex-col gap-4">
        {documents.isPending ? (
          <LoadingState label="Loading files…" />
        ) : documents.isError ? (
          <ErrorState compact error={documents.error} onRetry={() => void documents.refetch()} />
        ) : rows.length === 0 ? (
          <EmptyState compact title="No files yet" />
        ) : (
          <ul className="divide-line -my-2 divide-y">
            {rows.map((doc) => {
              const mine = doc.uploaded_by !== null && doc.uploaded_by === user?.id;
              return (
                <li key={doc.id} className="flex flex-wrap items-center gap-x-3 gap-y-2 py-3">
                  <FileText className="text-muted size-5 shrink-0" aria-hidden="true" />
                  <div className="min-w-0 flex-1">
                    {doc.url ? (
                      <a
                        href={doc.url}
                        target="_blank"
                        rel="noreferrer"
                        className="text-primary-ink block truncate text-sm font-medium hover:underline"
                      >
                        {doc.file_name}
                        <span className="sr-only"> (opens in a new tab)</span>
                      </a>
                    ) : (
                      <span className="text-ink block truncate text-sm font-medium">
                        {doc.file_name}
                      </span>
                    )}
                    <p className="text-muted text-xs">
                      {documentKindLabel(doc.content_type)} · {formatBytes(doc.size_bytes)} ·{' '}
                      {formatDateTime(doc.created_at, timezone)}
                    </p>
                  </div>
                  {canManage ? (
                    <span className="flex items-center gap-2">
                      <span aria-hidden="true" className="text-muted text-xs">
                        Customer sees
                      </span>
                      <Switch
                        aria-label={`Customer can see ${doc.file_name}`}
                        checked={doc.customer_visible}
                        disabled={setVisible.isPending}
                        onCheckedChange={(visible) =>
                          setVisible
                            .mutateAsync({ id: doc.id, visible })
                            .catch((error: unknown) => toast.error(error))
                        }
                      />
                    </span>
                  ) : (
                    doc.customer_visible && <Badge tone="success">Customer sees</Badge>
                  )}
                  {(canManage || mine) && (
                    <IconButton
                      size="sm"
                      variant="danger"
                      label={`Delete ${doc.file_name}`}
                      icon={<Trash2 className="size-4" />}
                      onClick={() => setDeleting(doc)}
                    />
                  )}
                </li>
              );
            })}
          </ul>
        )}
        <FileDropzone
          multiple
          maxFiles={MAX_FILES}
          accept={DOCUMENT_ACCEPT}
          maxBytes={DOCUMENT_MAX_BYTES}
          busy={uploading}
          label="Drop files here"
          description={`${DOCUMENT_FORMATS_TEXT}, up to ${formatBytes(DOCUMENT_MAX_BYTES)} each.`}
          buttonLabel="Add files"
          onFiles={(files) => void onFiles(files)}
          onReject={(message) => toast.error(message)}
        />
      </div>
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title="Delete this file?"
        description={deleting ? `“${deleting.file_name}” is removed for everyone.` : undefined}
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('File deleted');
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}
