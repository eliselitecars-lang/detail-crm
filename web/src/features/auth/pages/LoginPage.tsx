import { zodResolver } from '@hookform/resolvers/zod';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router';
import type { z } from 'zod';
import { AuthLayout } from '@/components/layout/AuthLayout';
import { Button, FormField, Input } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { useAuth } from '../authContext';
import { signInWithPassword } from '../api';
import { FormAlert } from '../FormAlert';
import { safeNext, signupPath } from '../redirects';
import { loginSchema } from '../schemas';

const schema = loginSchema;
type FormInput = z.input<typeof schema>;
type FormOutput = z.output<typeof schema>;

export default function LoginPage() {
  const { status } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const next = safeNext(params.get('next'));
  const [submitError, setSubmitError] = useState<string | null>(null);
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormInput, unknown, FormOutput>({
    resolver: zodResolver(schema),
    defaultValues: { email: '', password: '' },
  });

  if (status === 'signedIn') return <Navigate to={next} replace />;

  const onSubmit = handleSubmit(async (values) => {
    setSubmitError(null);
    try {
      await signInWithPassword(values.email, values.password);
      await navigate(next, { replace: true });
    } catch (error) {
      setSubmitError(errorMessage(error));
    }
  });

  return (
    <AuthLayout
      title="Sign in"
      description="Welcome back. Sign in to manage your shop."
      footer={
        <>
          New to Detail CRM?{' '}
          <Link
            to={signupPath(params.get('next') ?? undefined)}
            className="text-primary-ink font-medium hover:underline"
          >
            Create an account
          </Link>
        </>
      }
    >
      <form noValidate onSubmit={(event) => void onSubmit(event)} className="flex flex-col gap-4">
        {params.get('account') === 'deleted' && !submitError && (
          <FormAlert tone="success">Your account was deleted.</FormAlert>
        )}
        {submitError && <FormAlert>{submitError}</FormAlert>}
        <FormField label="Email" error={errors.email?.message} required>
          <Input type="email" autoComplete="email" {...register('email')} />
        </FormField>
        <FormField
          label="Password"
          error={errors.password?.message}
          required
          labelAside={
            <Link
              to="/forgot-password"
              className="text-primary-ink text-xs font-medium hover:underline"
            >
              Forgot password?
            </Link>
          }
        >
          <Input type="password" autoComplete="current-password" {...register('password')} />
        </FormField>
        <Button type="submit" loading={isSubmitting} fullWidth size="lg">
          Sign in
        </Button>
      </form>
    </AuthLayout>
  );
}
