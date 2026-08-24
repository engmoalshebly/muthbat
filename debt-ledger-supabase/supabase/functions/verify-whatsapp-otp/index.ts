import { optionsResponse } from "../_shared/cors.ts";
import { normalizeE164 } from "../_shared/crypto.ts";
import { errorResponse, json, rateLimitResponse, readJson, requirePost } from "../_shared/http.ts";
import { enforceRateLimits, RateLimitExceededError, requestAddress } from "../_shared/rate-limit.ts";
import { serviceClient } from "../_shared/supabase.ts";

interface VerifyOtpRequest {
  challengeId: string;
  code: string;
  phone: string;
  password?: string;
  displayName?: string;
  userType?: "merchant" | "customer";
  action: "signup" | "recovery";
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// Mutates an account only after atomically consuming a server-side OTP.
Deno.serve(async (request: Request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;

  try {
    const input = await readJson<VerifyOtpRequest>(request);
    if (
      !input ||
      typeof input !== "object" ||
      typeof input.challengeId !== "string" ||
      !UUID_PATTERN.test(input.challengeId) ||
      typeof input.code !== "string" ||
      !/^\d{6}$/.test(input.code.trim()) ||
      typeof input.phone !== "string" ||
      typeof input.password !== "string" ||
      input.password.length < 8 ||
      input.password.length > 128 ||
      !["signup", "recovery"].includes(input.action)
    ) {
      return errorResponse(request, 422, "invalid_request", "Verification data or password is invalid.");
    }

    let phone: string;
    try { phone = normalizeE164(input.phone); }
    catch { return errorResponse(request, 422, "invalid_phone", "Phone must be a valid E.164 number."); }

    try {
      await enforceRateLimits([
        { scope: "auth-otp-verify-ip", subjectKey: requestAddress(request), maxHits: 20, windowSeconds: 3600 },
        { scope: "auth-otp-verify-phone", subjectKey: phone, maxHits: 10, windowSeconds: 3600 },
      ]);
    } catch (error) {
      if (error instanceof RateLimitExceededError) return rateLimitResponse(request, error.retryAfterSeconds);
      throw error;
    }

    const admin = serviceClient();
    const { data: valid, error: verifyError } = await admin.rpc("service_verify_whatsapp_otp", {
      p_challenge_id: input.challengeId,
      p_code: input.code.trim(),
      p_phone: phone,
    });
    if (verifyError || valid !== true) return errorResponse(request, 400, "invalid_otp", "The verification code is invalid or expired.");

    const { data: users, error: usersError } = await admin.rpc("service_find_auth_user_by_phone", { p_phone: phone });
    if (usersError) throw usersError;
    const existingUserId = Array.isArray(users) ? (users[0]?.user_id as string | undefined) : undefined;

    if (input.action === "signup") {
      if (existingUserId) return errorResponse(request, 409, "account_exists", "An account already exists for this phone number.");

      const displayName = typeof input.displayName === "string" ? input.displayName.trim() : "New User";
      if (displayName.length < 2 || displayName.length > 120) {
        return errorResponse(request, 422, "invalid_display_name", "Display name must be between 2 and 120 characters.");
      }

      const { error } = await admin.auth.admin.createUser({
        phone,
        password: input.password,
        phone_confirm: true,
        user_metadata: {
          display_name: displayName,
          user_type: input.userType === "customer" ? "customer" : "merchant",
        },
      });
      if (error) throw error;
    } else {
      if (!existingUserId) return errorResponse(request, 400, "recovery_unavailable", "Account recovery is unavailable for this phone number.");

      const { error } = await admin.auth.admin.updateUserById(existingUserId, {
        password: input.password,
        phone_confirm: true,
      });
      if (error) throw error;

      // Existing access tokens are bounded by the JWT expiry configured for the project.
      // The client will receive a fresh session after signing in with the new password.
    }

    return json(request, { success: true, action: input.action }, 200);
  } catch (error) {
    console.error("verify_whatsapp_otp_error", error instanceof Error ? error.message : "unknown_error");
    return errorResponse(request, 500, "internal_error", "Unable to complete verification.");
  }
});
