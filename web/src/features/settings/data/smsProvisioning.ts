/**
 * Self-serve SMS numbers (P-14, ships dark): the sms-provisioning edge
 * function (platform) buys a Twilio number for the shop and submits its
 * toll-free / 10DLC verification. Every staff action answers 422
 * provisioning_disabled until the platform's Twilio account is approved
 * (SMS_PROVISIONING_ENABLED); 10DLC also needs TWILIO_ISV_ENABLED.
 * The current binding is read with sms_provisioning_status (owners/admins).
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { z } from 'zod';
import { EdgeFunctionError, toEdgeError } from '@/features/quotes/shared/edge';
import { useShop, useShopContext } from '@/features/shop/shopContext';
import { unwrap } from '@/lib/db';
import { supabase } from '@/lib/supabase';
import { settingsKeys } from '../api';

export const numberStatusSchema = z.object({
  number: z.string().nullable(),
  kind: z.enum(['tollfree', 'local']).nullable(),
  verification_status: z
    .enum(['not_started', 'pending', 'in_review', 'approved', 'rejected'])
    .nullable(),
  rejection_reason: z.string().nullable(),
  provisioned: z.boolean(),
});
export type SmsNumberStatus = z.infer<typeof numberStatusSchema>;
export type VerificationStatus = NonNullable<SmsNumberStatus['verification_status']>;

const flagsSchema = z.object({ enabled: z.boolean(), isv_enabled: z.boolean() });
export type ProvisioningFlags = z.infer<typeof flagsSchema>;

export const smsKeys = {
  status: (shopId: string) => [...settingsKeys.all(shopId), 'sms-number-status'] as const,
  flags: (shopId: string) => [...settingsKeys.all(shopId), 'sms-provisioning'] as const,
  search: (shopId: string, params: unknown) =>
    [...settingsKeys.all(shopId), 'sms-number-search', params] as const,
};

async function invokeProvisioning(action: string, body: Record<string, unknown>): Promise<unknown> {
  let response: Awaited<ReturnType<typeof supabase.functions.invoke<unknown>>>;
  try {
    response = await supabase.functions.invoke<unknown>('sms-provisioning', {
      body: { action, ...body },
    });
  } catch (error) {
    throw await toEdgeError(error);
  }
  if (response.error) throw await toEdgeError(response.error);
  return response.data;
}

/** True when the refusal means the feature is off on this platform. */
export function isProvisioningOff(error: unknown): boolean {
  return (
    error instanceof EdgeFunctionError &&
    (error.edgeCode === 'provisioning_disabled' || error.reason === 'provisioning_disabled')
  );
}

/** The shop's number and its verification (sms_provisioning_status). */
export function useSmsNumberStatus() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: smsKeys.status(shopId),
    queryFn: async (): Promise<SmsNumberStatus> =>
      numberStatusSchema.parse(
        unwrap(await supabase.rpc('sms_provisioning_status', { p_shop_id: shopId })),
      ),
  });
}

/**
 * A failure of the `status` call that means self-serve numbers are off on
 * this platform: the function refusing with provisioning_disabled, or not
 * being deployed at all (404). Anything else (offline, 5xx, a gateway
 * timeout) is a failure to check, not an answer.
 */
export function isProvisioningUnavailable(error: unknown): boolean {
  return isProvisioningOff(error) || (error instanceof EdgeFunctionError && error.status === 404);
}

/**
 * Whether self-serve numbers are available. A function that is off or not
 * deployed reads as "not available" (support connects the number instead).
 * A failure to reach it is an error the page shows with a retry: reading it
 * as "not available" would hide a number the shop already bought (its
 * verification, rejection reason, resubmit and release) behind the manual
 * support form.
 */
export function useProvisioningFlags() {
  const { shopId } = useShop();
  return useQuery({
    queryKey: smsKeys.flags(shopId),
    retry: (failures, error) => failures < 1 && !isProvisioningUnavailable(error),
    retryDelay: 500,
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<ProvisioningFlags> => {
      try {
        const data = await invokeProvisioning('status', { shop_id: shopId });
        const parsed = flagsSchema.safeParse(data);
        return parsed.success ? parsed.data : { enabled: false, isv_enabled: false };
      } catch (error) {
        if (isProvisioningUnavailable(error)) return { enabled: false, isv_enabled: false };
        throw error;
      }
    },
  });
}

const searchSchema = z.object({
  numbers: z.array(
    z.object({
      phone_e164: z.string(),
      locality: z.string().nullable().optional(),
      region: z.string().nullable().optional(),
    }),
  ),
});
export type AvailableNumber = z.infer<typeof searchSchema>['numbers'][number];

export interface NumberSearch {
  kind: 'tollfree' | 'local';
  areaCode?: string;
  contains?: string;
}

export function useSearchNumbers(search: NumberSearch | null) {
  const { shopId } = useShop();
  return useQuery({
    queryKey: smsKeys.search(shopId, search),
    enabled: search !== null,
    retry: false,
    queryFn: async (): Promise<AvailableNumber[]> => {
      const params = search ?? { kind: 'tollfree' };
      return searchSchema.parse(
        await invokeProvisioning('search_numbers', {
          shop_id: shopId,
          kind: params.kind,
          ...(params.areaCode ? { area_code: params.areaCode } : {}),
          ...(params.contains ? { contains: params.contains } : {}),
        }),
      ).numbers;
    },
  });
}

function useAfterNumberChange() {
  const { shopId } = useShop();
  const { refetch } = useShopContext();
  const queryClient = useQueryClient();
  return () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: smsKeys.status(shopId) }),
      queryClient.invalidateQueries({ queryKey: settingsKeys.shop(shopId) }),
      refetch(),
    ]);
}

export function usePurchaseNumber() {
  const { shopId } = useShop();
  const after = useAfterNumberChange();
  return useMutation({
    mutationFn: async ({ phone, nonce }: { phone: string; nonce: string }) =>
      invokeProvisioning('purchase_number', {
        shop_id: shopId,
        phone_e164: phone,
        request_nonce: nonce,
      }),
    onSettled: after,
  });
}

/** Toll-free verification details (sms-provisioning tollfreeBusinessSchema; never secrets). */
export interface BusinessInfo {
  legal_name: string;
  website: string;
  address_line1: string;
  address_line2?: string;
  city: string;
  region: string;
  postal_code: string;
  country: 'US' | 'CA';
  contact_first_name: string;
  contact_last_name: string;
  contact_email: string;
  contact_phone: string;
  use_case_categories: string[];
  use_case_summary: string;
  production_message_sample: string;
  opt_in_type: string;
  opt_in_image_urls: string[];
  estimated_monthly_volume: string;
}

/** 10DLC brand details (sms-provisioning a2pBusinessSchema). */
export interface A2pBusiness {
  legal_name: string;
  business_type: string;
  industry: string;
  registration_identifier: 'EIN' | 'CBN';
  registration_number: string;
  website: string;
  regions_of_operation: string[];
  company_type: 'private' | 'public' | 'non-profit' | 'government';
  stock_exchange?: string;
  stock_ticker?: string;
  address_line1: string;
  address_line2?: string;
  city: string;
  region: string;
  postal_code: string;
  country: 'US' | 'CA';
  email: string;
  representative: {
    first_name: string;
    last_name: string;
    email: string;
    phone: string;
    business_title: string;
    job_position: string;
  };
}

/** 10DLC campaign (sms-provisioning a2pCampaignSchema). */
export interface A2pCampaign {
  use_case: string;
  description: string;
  message_flow: string;
  message_samples: string[];
  has_embedded_links: boolean;
  has_embedded_phone: boolean;
}

export type VerificationSubmission =
  | { kind: 'tollfree'; business: BusinessInfo; editReason?: string }
  | { kind: 'local'; business: A2pBusiness; campaign: A2pCampaign };

export function useSubmitVerification() {
  const { shopId } = useShop();
  const after = useAfterNumberChange();
  return useMutation({
    mutationFn: async (submission: VerificationSubmission) =>
      submission.kind === 'tollfree'
        ? invokeProvisioning('submit_tollfree_verification', {
            shop_id: shopId,
            business: submission.business,
            ...(submission.editReason ? { edit_reason: submission.editReason } : {}),
          })
        : invokeProvisioning('submit_10dlc', {
            shop_id: shopId,
            business: submission.business,
            campaign: submission.campaign,
          }),
    onSettled: after,
  });
}

export function useReleaseNumber() {
  const { shopId } = useShop();
  const after = useAfterNumberChange();
  return useMutation({
    mutationFn: async () => invokeProvisioning('release_number', { shop_id: shopId }),
    onSettled: after,
  });
}
