import { ImageOff, ImagePlus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import {
  buttonClasses,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  IconButton,
  LoadingState,
  SectionCard,
  Select,
  Spinner,
  useToast,
} from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatDateTime } from '@/lib/dates';
import { useAuth } from '@/features/auth/authContext';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useDeletePhoto, usePhotos, useUploadPhoto, type JobPhoto } from '../../fieldApi';
import { PHOTO_KIND_LABELS, PHOTO_MIME_TYPES, photoProblem, type JobPhotoKind } from '../../model';

const KIND_ORDER: JobPhotoKind[] = ['before', 'after', 'inspection', 'other'];

export function PhotosCard({ jobId }: { jobId: string }) {
  const { timezone } = useShop();
  const { user } = useAuth();
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const photos = usePhotos(jobId);
  const upload = useUploadPhoto(jobId);
  const remove = useDeletePhoto(jobId);
  const [kind, setKind] = useState<JobPhotoKind>('before');
  const [uploading, setUploading] = useState(0);
  const [deleting, setDeleting] = useState<JobPhoto | null>(null);

  const onFiles = async (files: FileList | null) => {
    const list = Array.from(files ?? []);
    if (list.length === 0) return;
    setUploading(list.length);
    let ok = 0;
    for (const file of list) {
      const problem = photoProblem(file);
      if (problem) {
        toast.error(`${file.name}: ${problem}`);
        setUploading((n) => n - 1);
        continue;
      }
      try {
        await upload.mutateAsync({ file, kind, caption: null });
        ok += 1;
      } catch (error) {
        toast.error(error, file.name);
      }
      setUploading((n) => n - 1);
    }
    if (ok > 0) toast.success(ok === 1 ? 'Photo uploaded' : `${ok} photos uploaded`);
  };

  const rows = photos.data ?? [];

  return (
    <SectionCard
      title="Photos"
      actions={
        <div className="flex flex-wrap items-center gap-2">
          <Select
            aria-label="Photo type"
            selectSize="sm"
            value={kind}
            onChange={(e) => {
              const next = KIND_ORDER.find((k) => k === e.target.value);
              if (next) setKind(next);
            }}
            options={(['before', 'after', 'other'] as const).map((k) => ({
              value: k,
              label: PHOTO_KIND_LABELS[k],
            }))}
          />
          <label
            className={cn(
              buttonClasses({ variant: 'secondary', size: 'sm' }),
              'cursor-pointer focus-within:outline-2 focus-within:outline-offset-2',
              uploading > 0 && 'pointer-events-none opacity-60',
            )}
          >
            {uploading > 0 ? (
              <Spinner className="size-4" />
            ) : (
              <ImagePlus className="size-4" aria-hidden="true" />
            )}
            {uploading > 0 ? `Uploading ${uploading}…` : 'Upload'}
            <input
              type="file"
              className="sr-only"
              accept={PHOTO_MIME_TYPES.join(',')}
              multiple
              disabled={uploading > 0}
              onChange={(e) => {
                const files = e.target.files;
                void onFiles(files).finally(() => {
                  e.target.value = '';
                });
              }}
            />
          </label>
        </div>
      }
    >
      {photos.isPending ? (
        <LoadingState label="Loading photos…" />
      ) : photos.isError ? (
        <ErrorState compact error={photos.error} onRetry={() => void photos.refetch()} />
      ) : rows.length === 0 ? (
        <EmptyState compact title="No photos yet" description="Upload before and after photos." />
      ) : (
        <div className="flex flex-col gap-4">
          {KIND_ORDER.map((k) => {
            const group = rows.filter((p) => p.kind === k);
            if (group.length === 0) return null;
            return (
              <section key={k} aria-label={`${PHOTO_KIND_LABELS[k]} photos`}>
                <h4 className="text-muted mb-2 text-xs font-semibold tracking-wide uppercase">
                  {PHOTO_KIND_LABELS[k]} ({group.length})
                </h4>
                <ul className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4">
                  {group.map((photo) => {
                    const alt = `${PHOTO_KIND_LABELS[photo.kind]} photo from ${formatDateTime(photo.created_at, timezone)}`;
                    const mine = photo.uploaded_by !== null && photo.uploaded_by === user?.id;
                    return (
                      <li
                        key={photo.id}
                        className="border-line bg-surface-2 relative aspect-square overflow-hidden rounded-control border"
                      >
                        {photo.url ? (
                          <a href={photo.url} target="_blank" rel="noreferrer" className="block size-full">
                            <img
                              src={photo.url}
                              alt={alt}
                              loading="lazy"
                              className="size-full object-cover"
                            />
                          </a>
                        ) : (
                          <div className="text-muted flex size-full items-center justify-center">
                            <ImageOff className="size-5" aria-hidden="true" />
                            <span className="sr-only">{alt} (unavailable)</span>
                          </div>
                        )}
                        {(canManage || mine) && (
                          <IconButton
                            size="sm"
                            variant="secondary"
                            className="absolute top-1 right-1"
                            label={`Delete ${alt}`}
                            icon={<Trash2 className="size-4" />}
                            onClick={() => setDeleting(photo)}
                          />
                        )}
                      </li>
                    );
                  })}
                </ul>
              </section>
            );
          })}
        </div>
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title="Delete this photo?"
        description="It is removed from the job for everyone."
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting);
            toast.success('Photo deleted');
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}
