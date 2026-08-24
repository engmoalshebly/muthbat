-- ============================================================================
-- Supabase Local Seed Data for Muthbat / Debt-Ledger
-- ============================================================================
-- Note: Authentication users should be created via the OpenWA OTP flow or local Auth API.
-- This file initializes clean default configurations and test templates.

-- 1. Ensure private schema and extensions are available
CREATE SCHEMA IF NOT EXISTS private;

-- 2. Optional: Seed demo OTP challenge for local test phone +967700000001 (Code: 123456)
-- Hash of '123456' using SHA-256: 8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92
INSERT INTO private.otp_challenges (
    phone_e164,
    code_hash,
    attempts_left,
    expires_at,
    last_sent_at
) VALUES (
    '+967700000001',
    '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92',
    5,
    now() + interval '30 days',
    now()
) ON CONFLICT DO NOTHING;
