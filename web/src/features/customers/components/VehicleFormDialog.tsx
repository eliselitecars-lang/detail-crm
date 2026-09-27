import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation } from '@tanstack/react-query';
import { ScanLine } from 'lucide-react';
import { useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { Button, Dialog, FormField, Input, Select, Textarea, useToast } from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { errorMessage, toAppError } from '@/lib/errors';
import { useSaveVehicle, useVehicleCategories } from '../api';
import type { VehicleRow } from '../model';
import {
  emptyVehicleForm,
  vehicleFormSchema,
  vehicleFormToWrite,
  vehicleToForm,
  type VehicleFormInput,
  type VehicleFormValues,
} from '../schemas';
import { decodeVin, VIN_PROBLEM_TEXT, vinProblem, type DecodedVin } from '../vin';

export interface VehicleFormDialogProps {
  customerId: string;
  vehicle?: VehicleRow;
  onClose: () => void;
  /** Injected in tests. */
  fetchImpl?: typeof fetch;
}

const CONSTRAINT_FIELDS: Record<string, keyof VehicleFormInput> = {
  vehicles_year_check: 'year',
  vehicles_make_check: 'make',
  vehicles_model_check: 'model',
  vehicles_trim_check: 'trim',
  vehicles_color_check: 'color',
  vehicles_vin_check: 'vin',
  vehicles_license_plate_check: 'licensePlate',
  vehicles_notes_check: 'notes',
};

/** Add / edit a vehicle, with VIN decode via NHTSA vPIC. Mount only while open. */
export function VehicleFormDialog({
  customerId,
  vehicle,
  onClose,
  fetchImpl,
}: VehicleFormDialogProps) {
  const { shopId } = useShop();
  const toast = useToast();
  const save = useSaveVehicle(shopId, customerId);
  const categories = useVehicleCategories(shopId);
  const [formError, setFormError] = useState<string | null>(null);
  const [decodeNote, setDecodeNote] = useState<string | null>(null);
  const [vinHint, setVinHint] = useState<string | null>(null);

  const {
    register,
    control,
    handleSubmit,
    setError,
    getValues,
    setValue,
    formState: { errors, isSubmitting },
  } = useForm<VehicleFormInput, unknown, VehicleFormValues>({
    resolver: zodResolver(vehicleFormSchema),
    mode: 'onTouched',
    defaultValues: vehicle ? vehicleToForm(vehicle) : emptyVehicleForm(),
  });

  const decode = useMutation({
    mutationFn: (vin: string) => decodeVin(vin, fetchImpl ? { fetchImpl } : {}),
    onSuccess: (decoded: DecodedVin) => {
      const opts = { shouldDirty: true, shouldValidate: true } as const;
      if (decoded.year !== null) setValue('year', String(decoded.year), opts);
      if (decoded.make) setValue('make', decoded.make, opts);
      if (decoded.model) setValue('model', decoded.model, opts);
      if (decoded.trim) setValue('trim', decoded.trim, opts);
      const found = [decoded.year, decoded.make, decoded.model, decoded.trim].filter(
        (v) => v !== null && v !== '',
      );
      setDecodeNote(`Filled in ${found.join(' ')} from the VIN. Check it before saving.`);
    },
  });

  const onDecode = () => {
    setDecodeNote(null);
    setVinHint(null);
    decode.reset();
    const vin = getValues('vin');
    const problem = vinProblem(vin);
    if (problem) {
      setVinHint(VIN_PROBLEM_TEXT[problem]);
      return;
    }
    decode.mutate(vin);
  };

  const onSubmit = handleSubmit(async (values) => {
    setFormError(null);
    try {
      await save.mutateAsync({ id: vehicle?.id ?? null, values: vehicleFormToWrite(values) });
      toast.success(vehicle ? 'Vehicle saved' : 'Vehicle added');
      onClose();
    } catch (error) {
      const appError = toAppError(error);
      const field = appError.constraint ? CONSTRAINT_FIELDS[appError.constraint] : undefined;
      if (field) setError(field, { message: appError.message }, { shouldFocus: true });
      else setFormError(appError.message);
    }
  });

  const formId = 'vehicle-form';
  const categoryOptions = (categories.data ?? []).map((c) => ({ value: c.id, label: c.name }));

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!isSubmitting}
      size="lg"
      title={vehicle ? 'Edit vehicle' : 'Add vehicle'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={isSubmitting}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={isSubmitting}>
            {vehicle ? 'Save vehicle' : 'Add vehicle'}
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="flex flex-col gap-4"
      >
        {formError && (
          <p
            role="alert"
            className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
          >
            {formError}
          </p>
        )}
        <div className="flex flex-col gap-2">
          <FormField
            label="VIN"
            error={errors.vin?.message}
            help="17 characters. Decode fills in year, make, model and trim."
          >
            <div className="flex flex-col gap-2 min-[420px]:flex-row">
              <Input
                className="min-[420px]:flex-1"
                autoComplete="off"
                autoCapitalize="characters"
                spellCheck={false}
                maxLength={20}
                {...register('vin')}
              />
              <Button
                type="button"
                variant="secondary"
                loading={decode.isPending}
                leadingIcon={<ScanLine className="size-4" aria-hidden="true" />}
                onClick={onDecode}
              >
                Decode VIN
              </Button>
            </div>
          </FormField>
          <div aria-live="polite" className="text-sm">
            {(vinHint !== null || decode.isError) && (
              <p role="alert" className="text-danger-ink">
                {vinHint ?? errorMessage(decode.error)}
              </p>
            )}
            {decodeNote && <p className="text-success-ink">{decodeNote}</p>}
          </div>
        </div>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-4">
          <FormField label="Year" error={errors.year?.message}>
            <Input inputMode="numeric" maxLength={4} autoComplete="off" {...register('year')} />
          </FormField>
          <FormField label="Make" error={errors.make?.message} className="sm:col-span-3">
            <Input autoComplete="off" {...register('make')} />
          </FormField>
          <FormField label="Model" error={errors.model?.message} className="sm:col-span-2">
            <Input autoComplete="off" {...register('model')} />
          </FormField>
          <FormField label="Trim" error={errors.trim?.message} className="sm:col-span-2">
            <Input autoComplete="off" {...register('trim')} />
          </FormField>
          <FormField label="Color" error={errors.color?.message} className="sm:col-span-2">
            <Input autoComplete="off" {...register('color')} />
          </FormField>
          <FormField
            label="License plate"
            error={errors.licensePlate?.message}
            className="sm:col-span-2"
          >
            <Input autoComplete="off" autoCapitalize="characters" {...register('licensePlate')} />
          </FormField>
          <FormField
            label="Size category"
            error={errors.categoryId?.message}
            help="Used to price services for this vehicle."
            className="sm:col-span-4"
          >
            <Controller
              control={control}
              name="categoryId"
              render={({ field }) => (
                <Select
                  name={field.name}
                  ref={field.ref}
                  value={field.value}
                  onChange={field.onChange}
                  onBlur={field.onBlur}
                  placeholder={categories.isPending ? 'Loading…' : 'Not set'}
                  options={categoryOptions}
                />
              )}
            />
          </FormField>
          <FormField label="Notes" error={errors.notes?.message} className="sm:col-span-4">
            <Textarea rows={3} {...register('notes')} />
          </FormField>
        </div>
      </form>
    </Dialog>
  );
}
