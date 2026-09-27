import { z } from 'zod';
import { zEmail, zPassword, zRequiredText } from '@/lib/validation';

export const loginSchema = z.object({
  email: zEmail,
  password: z.string().min(1, 'Password is required.'),
});

export const signupSchema = z
  .object({
    fullName: zRequiredText('Your name', 200),
    email: zEmail,
    password: zPassword,
    confirmPassword: z.string(),
  })
  .refine((v) => v.password === v.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords don’t match.',
  });

export const forgotPasswordSchema = z.object({ email: zEmail });

export const resetPasswordSchema = z
  .object({
    password: zPassword,
    confirmPassword: z.string(),
  })
  .refine((v) => v.password === v.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords don’t match.',
  });
