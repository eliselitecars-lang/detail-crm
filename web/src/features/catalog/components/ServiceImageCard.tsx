import { ImagePlus, Trash2 } from 'lucide-react';
import { useId, useRef, useState } from 'react';
import { Button, SectionCard, useToast } from '@/components/ui';
import { shopAssetUrl } from '@/lib/supabase';
import { useShop } from '@/features/shop/shopContext';
import { useRemoveServiceImage, useUploadServiceImage } from '../api';
import { imageFileError, type ServiceRow } from '../model';

/**
 * Service photo in the public shop-assets bucket. The bucket's storage
 * policies only let owners/admins write, so managers see the image but not
 * the upload controls.
 */
export function ServiceImageCard({
  service,
  canManage,
}: {
  service: ServiceRow;
  canManage: boolean;
}) {
  const { role } = useShop();
  const toast = useToast();
  const inputId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const upload = useUploadServiceImage(service);
  const remove = useRemoveServiceImage(service);
  const [error, setError] = useState<string | null>(null);
  const canUpload = canManage && (role === 'owner' || role === 'admin');

  const url = shopAssetUrl(service.image_path);
  // The path is reused on replace; bust caches with the row's updated_at.
  const src = url ? `${url}?v=${encodeURIComponent(service.updated_at)}` : null;

  const onFile = async (file: File | undefined) => {
    if (!file) return;
    const problem = imageFileError(file);
    setError(problem);
    if (problem) return;
    try {
      await upload.mutateAsync(file);
      toast.success('Image updated');
    } catch (err) {
      toast.error(err);
    } finally {
      if (inputRef.current) inputRef.current.value = '';
    }
  };

  return (
    <SectionCard title="Image" description="Shown on your booking page.">
      <div className="flex flex-col gap-3">
        {src ? (
          <img
            src={src}
            alt={`${service.name}`}
            className="rounded-control border-line aspect-video w-full border object-cover"
          />
        ) : (
          <div className="rounded-control border-line bg-surface-2 text-muted flex aspect-video w-full items-center justify-center border border-dashed text-sm">
            No image
          </div>
        )}
        {canUpload ? (
          <div className="flex flex-wrap gap-2">
            <input
              ref={inputRef}
              id={inputId}
              type="file"
              accept="image/png,image/jpeg,image/webp"
              className="sr-only"
              tabIndex={-1}
              aria-hidden="true"
              onChange={(e) => void onFile(e.target.files?.[0])}
            />
            <Button
              variant="secondary"
              size="sm"
              leadingIcon={<ImagePlus />}
              loading={upload.isPending}
              onClick={() => inputRef.current?.click()}
            >
              {src ? 'Replace image' : 'Upload image'}
            </Button>
            {src && (
              <Button
                variant="ghost"
                size="sm"
                leadingIcon={<Trash2 />}
                loading={remove.isPending}
                onClick={() =>
                  remove.mutate(undefined, {
                    onSuccess: () => toast.success('Image removed'),
                    onError: (err) => toast.error(err),
                  })
                }
              >
                Remove
              </Button>
            )}
          </div>
        ) : (
          canManage && (
            <p className="text-muted text-xs">Only an owner or admin can change images.</p>
          )
        )}
        {error ? (
          <p role="alert" className="text-danger-ink text-xs font-medium">
            {error}
          </p>
        ) : (
          canUpload && <p className="text-muted text-xs">PNG, JPEG or WebP, up to 5 MB.</p>
        )}
      </div>
    </SectionCard>
  );
}
