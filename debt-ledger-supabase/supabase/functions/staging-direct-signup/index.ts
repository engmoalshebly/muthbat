import { optionsResponse } from "../_shared/cors.ts";
import { normalizeE164 } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { enforceRateLimits, RateLimitExceededError, requestAddress } from "../_shared/rate-limit.ts";
import { serviceClient } from "../_shared/supabase.ts";

interface DirectSignupRequest {
  phone: string;
  password: string;
  displayName: string;
  userType?: "merchant" | "customer";
}

// This exists only to unblock a closed staging test while WhatsApp delivery is
// unavailable. It is deliberately fail-closed and must never be enabled in
// production. The client still receives a normal GoTrue session afterwards.
Deno.serve(async (request: Request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;

  if (Deno.env.get("APP_ENV") !== "staging" || Deno.env.get("ALLOW_STAGING_DIRECT_AUTH") !== "true") {
    return errorResponse(request, 403, "direct_auth_disabled", "Direct authentication is disabled.");
  }

  try {
    const input = await readJson<DirectSignupRequest>(request);
    if (!input || typeof input.phone !== "string" || typeof input.password !== "string" || typeof input.displayName !== "string") {
      return errorResponse(request, 422, "invalid_request", "Registration data is invalid.");
    }
    if (input.password.length < 8 || input.password.length > 128) {
      return errorResponse(request, 422, "invalid_password", "Password must be between 8 and 128 characters.");
    }
    const displayName = input.displayName.trim();
    if (displayName.length < 2 || displayName.length > 120) {
      return errorResponse(request, 422, "invalid_display_name", "Display name must be between 2 and 120 characters.");
    }

    let phone: string;
    try { phone = normalizeE164(input.phone); }
    catch { return errorResponse(request, 422, "invalid_phone", "Phone must be a valid E.164 number."); }

    try {
      await enforceRateLimits([
        { scope: "staging-direct-signup-ip", subjectKey: requestAddress(request), maxHits: 10, windowSeconds: 3600 },
        { scope: "staging-direct-signup-phone", subjectKey: phone, maxHits: 3, windowSeconds: 3600 },
      ]);
    } catch (error) {
      if (error instanceof RateLimitExceededError) return errorResponse(request, 429, "rate_limited", "Too many requests. Please try again later.");
      throw error;
    }

    const admin = serviceClient();
    const { data: users, error: usersError } = await admin.rpc("service_find_auth_user_by_phone", { p_phone: phone });
    if (usersError) throw usersError;
    if (Array.isArray(users) && users.length > 0) {
      return errorResponse(request, 409, "account_exists", "An account already exists for this phone number.");
    }

    const { error: createError } = await admin.auth.admin.createUser({
      phone,
      password: input.password,
      phone_confirm: true,
      app_metadata: { phone_verification_bypassed: true },
      user_metadata: {
        display_name: displayName,
        user_type: input.userType === "customer" ? "customer" : "merchant",
      },
    });
    if (createError) throw createError;

    return json(request, { success: true, directAuth: true }, 201);
  } catch (error) {
    console.error("staging_direct_signup_error", error instanceof Error ? error.message : "unknown_error");
    return errorResponse(request, 500, "internal_error", "Unable to complete direct registration.");
  }
});
