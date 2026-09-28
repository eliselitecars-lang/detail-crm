import { ExternalLink, FileText, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router';
import {
  Badge,
  Card,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  FileDropzone,
  formatBytes,
  IconButton,
  LoadingState,
  Switch,
  useToast,
} from '@/components/ui';
import { formatDateTime } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import {
  DOCUMENT_ACCEPT,
  DOCUMENT_FORMATS_TEXT,
  DOCUMENT_MAX_BYTES,
  documentKindLabel,
  documentProblem,
} from '@/features/jobs/documents';
import {
  useCustomerDocuments,
  useDeleteCustomerDocument,
  useSetCustomerDocumentVisible,
  useUploadCustomerDocument,
  type CustomerDocument,
} from '../parityApi';

const MAX_FILES = 10;

/**
 * Files on the customer (signed agreements, fleet paperwork, photos) plus
 * the files of their jobs. Managers+ (RLS): upload, share with the customer
 * (their portal), delete.
 */
export function DocumentsTab({
  customerId,
  archivedCustomer,
}: {
  customerId: string;
  archivedCustomer: boolean;
}) {
  const { timezone } = useShop();
  const toast = useToast();
  const canManage = useCan('customers.manage');
  const documents = useCustomerDocuments(customerId, canManage);
  const upload = useUploadCustomerDocument(customerId);
  const setVisible = useSetCustomerDocumentVisible(customerId);
  const remove = useDeleteCustomerDocument(customerId);
  const [uploading, setUploading] = useState(false);
  const [deleting, setDeleting] = useState<CustomerDocument | null>(null);

  const onFiles = async (files: File[]) => {
    setUploading(true);
    let added = 0;
    try {
      for (const file of files) {
        const problem = documentProblem(file);
        if (problem) {
          toast.error(`${file.name}: ${problem}`);
          continue;
        }
        try {
          await upload.mutateAsync(file);
          added += 1;
        } catch (error) {
          toast.error(error);
        }
      }
      if (added > 0) toast.success(added === 1 ? 'File added' : `${added} files added`);
    } finally {
      setUploading(false);
    }
  };

  const toggleVisible = async (doc: CustomerDocument, visible: boolean) => {
    try {
      await setVisible.mutateAsync({ id: doc.id, visible });
      toast.success(visible ? 'Shared with the customer' : 'Hidden from the customer');
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <Card className="overflow-hidden">
      {documents.isPending ? (
        <LoadingState variant="rows" rows={3} label="Loading files…" />
      ) : documents.isError ? (
        <ErrorState error={documents.error} onRetry={() => void documents.refetch()} />
      ) : documents.data.length === 0 ? (
        <EmptyState
          compact
          icon={<FileText aria-hidden="true" />}
          title="No files yet"
          description="Add agreements, fleet paperwork or photos for this customer."
        />
      ) : (
        <ul className="divide-line divide-y" aria-label="Files">
          {documents.data.map((doc) => (
            <li key={doc.id} className="flex flex-wrap items-start gap-3 px-4 py-3">
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  {doc.url ? (
                    <a
                      href={doc.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-ink hover:text-primary-ink inline-flex items-center gap-1 text-sm font-medium break-all hover:underline"
                    >
                      {doc.file_name}
                      <ExternalLink className="size-3.5 shrink-0" aria-hidden="true" />
                    </a>
                  ) : (
                    <span className="text-ink text-sm font-medium break-all">{doc.file_name}</span>
                  )}
                  <Badge tone="neutral">{documentKindLabel(doc.content_type)}</Badge>
                  {doc.job_id && (
                    <Link
                      to={`/app/jobs/${doc.job_id}`}
                      className="text-primary-ink text-xs hover:underline"
                    >
                      {doc.job_number !== null ? `Job #${doc.job_number}` : 'From a job'}
                    </Link>
                  )}
                </div>
                <p className="text-muted mt-0.5 text-xs">
                  {formatBytes(doc.size_bytes)} · added {formatDateTime(doc.created_at, timezone)}
                </p>
              </div>
              <div className="flex shrink-0 items-center gap-3">
                <Switch
                  checked={doc.customer_visible}
                  disabled={setVisible.isPending}
                  onCheckedChange={(on) => void toggleVisible(doc, on)}
                  label="Customer can see"
                />
                <IconButton
                  size="sm"
                  variant="ghost"
                  label={`Delete ${doc.file_name}`}
                  icon={<Trash2 className="size-4" />}
                  onClick={() => setDeleting(doc)}
                />
              </div>
            </li>
          ))}
        </ul>
      )}
      {!archivedCustomer && (
        <div className="border-line border-t p-4">
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
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        loading={remove.isPending}
        tone="danger"
        title="Delete this file?"
        description={deleting ? `“${deleting.file_name}” is removed for good.` : undefined}
        confirmLabel="Delete file"
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
    </Card>
  );
}
