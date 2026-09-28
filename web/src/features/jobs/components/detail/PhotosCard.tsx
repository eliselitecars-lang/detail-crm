import { Eye, EyeOff, ImageOff, ImagePlus, Trash2, Video } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
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
import {
  useDeletePhoto,
  usePhotos,
  useSetPhotoVisibility,
  useUploadPhoto,
  type JobPhoto,
} from '../../fieldApi';
import {
  formatVideoLength,
  PHOTO_KIND_LABELS,
  PHOTO_MIME_TYPES,
  photoProblem,
  type JobPhotoKind,
} from '../../model';

const KIND_ORDER: JobPhotoKind[] = ['before', 'after', 'inspection', 'other'];

/**
 * Photos and videos of the job. Staff on the job choose which ones the
 * customer sees on the job report (P-8); videos are recorded and uploaded in
 * the iPhone app and play here (P-30).
 */
export function PhotosCard({ jobId }: { jobId: string }) {
  const { timezone } = useShop();
  const { user } = useAuth();
  const canManage = useCan('jobs.manage');
  const toast = useToast();
  const photos = usePhotos(jobId);
  const upload = useUploadPhoto(jobId);
  const remove = useDeletePhoto(jobId);
  const visibility = useSetPhotoVisibility(jobId);
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

  const setVisible = async (ids: string[], visible: boolean) => {
    try {
      const count = await visibility.mutateAsync({ ids, visible });
      const what = count === 1 ? '1 item' : `${count} items`;
      toast.success(
        visible ? `${what} shown on the customer’s report` : `${what} hidden from the customer`,
      );
    } catch (error) {
      toast.error(error);
    }
  };

  const rows = photos.data ?? [];
  const hidden = rows.filter((p) => !p.customer_visible).map((p) => p.id);
  const shown = rows.filter((p) => p.customer_visible).map((p) => p.id);

  return (
    <SectionCard
      title="Photos & videos"
      description={
        rows.length > 0
          ? `${shown.length} of ${rows.length} visible to the customer on the job report`
          : undefined
      }
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
        <EmptyState
          compact
          title="No photos yet"
          description="Upload before and after photos. Videos are recorded in the iPhone app."
        />
      ) : (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap gap-2">
            <Button
              size="sm"
              variant="ghost"
              leadingIcon={<Eye className="size-4" aria-hidden="true" />}
              disabled={hidden.length === 0 || visibility.isPending}
              onClick={() => void setVisible(hidden, true)}
            >
              Show all to customer
            </Button>
            <Button
              size="sm"
              variant="ghost"
              leadingIcon={<EyeOff className="size-4" aria-hidden="true" />}
              disabled={shown.length === 0 || visibility.isPending}
              onClick={() => void setVisible(shown, false)}
            >
              Hide all from customer
            </Button>
          </div>
          {KIND_ORDER.map((k) => {
            const group = rows.filter((p) => p.kind === k);
            if (group.length === 0) return null;
            return (
              <section key={k} aria-label={`${PHOTO_KIND_LABELS[k]} photos`}>
                <h4 className="text-muted mb-2 text-xs font-semibold tracking-wide uppercase">
                  {PHOTO_KIND_LABELS[k]} ({group.length})
                </h4>
                <ul className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4">
                  {group.map((photo) => (
                    <PhotoTile
                      key={photo.id}
                      photo={photo}
                      timezone={timezone}
                      canDelete={
                        canManage || (photo.uploaded_by !== null && photo.uploaded_by === user?.id)
                      }
                      busy={visibility.isPending}
                      onToggleVisible={() => void setVisible([photo.id], !photo.customer_visible)}
                      onDelete={() => setDeleting(photo)}
                    />
                  ))}
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
        title={deleting?.mediaType === 'video' ? 'Delete this video?' : 'Delete this photo?'}
        description="It is removed from the job for everyone."
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting);
            toast.success(deleting.mediaType === 'video' ? 'Video deleted' : 'Photo deleted');
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}

interface PhotoTileProps {
  photo: JobPhoto;
  timezone: string;
  canDelete: boolean;
  busy: boolean;
  onToggleVisible: () => void;
  onDelete: () => void;
}

function PhotoTile({
  photo,
  timezone,
  canDelete,
  busy,
  onToggleVisible,
  onDelete,
}: PhotoTileProps) {
  const video = photo.mediaType === 'video';
  const alt = `${PHOTO_KIND_LABELS[photo.kind]} ${video ? 'video' : 'photo'} from ${formatDateTime(photo.created_at, timezone)}`;
  const length = formatVideoLength(photo.duration_seconds);
  return (
    <li className="border-line bg-surface-2 rounded-control relative aspect-square overflow-hidden border">
      {photo.url ? (
        video ? (
          // eslint-disable-next-line jsx-a11y/media-has-caption -- job videos have no speech to caption
          <video
            src={photo.url}
            poster={photo.posterUrl ?? undefined}
            controls
            preload="metadata"
            playsInline
            aria-label={alt}
            className="bg-surface-3 size-full object-contain"
          />
        ) : (
          <a href={photo.url} target="_blank" rel="noreferrer" className="block size-full">
            <img src={photo.url} alt={alt} loading="lazy" className="size-full object-cover" />
          </a>
        )
      ) : (
        <div className="text-muted flex size-full items-center justify-center">
          {video ? (
            <Video className="size-5" aria-hidden="true" />
          ) : (
            <ImageOff className="size-5" aria-hidden="true" />
          )}
          <span className="sr-only">{alt} (unavailable)</span>
        </div>
      )}
      <div className="pointer-events-none absolute inset-x-1 top-1 flex items-start justify-between gap-1">
        <span className="flex flex-col items-start gap-1">
          {video && (
            <Badge tone="info">
              <Video className="size-3" aria-hidden="true" />
              Video{length ? ` · ${length}` : ''}
            </Badge>
          )}
          {photo.customer_visible && <Badge tone="success">Customer sees</Badge>}
        </span>
        <span className="pointer-events-auto flex gap-1">
          <IconButton
            size="sm"
            variant="secondary"
            label={
              photo.customer_visible
                ? `Hide ${alt} from the customer`
                : `Show ${alt} to the customer`
            }
            icon={
              photo.customer_visible ? <EyeOff className="size-4" /> : <Eye className="size-4" />
            }
            disabled={busy}
            onClick={onToggleVisible}
          />
          {canDelete && (
            <IconButton
              size="sm"
              variant="secondary"
              label={`Delete ${alt}`}
              icon={<Trash2 className="size-4" />}
              onClick={onDelete}
            />
          )}
        </span>
      </div>
    </li>
  );
}
