/**
 * `@/lib/supabase` replacement for the public pages' tests: the shared mock
 * plus `functions.invoke` and a storage bucket with `upload`.
 *   vi.mock('@/lib/supabase', () => import('@/features/public-docs/shared/testSupabase'));
 */
import * as base from '@/test/supabaseMock';
import { edge } from './testing';

Object.assign(base.supabase, { functions: edge });

export const supabase = base.supabase;
export const isSupabaseConfigured = base.isSupabaseConfigured;
export const shopAssetUrl = base.shopAssetUrl;
