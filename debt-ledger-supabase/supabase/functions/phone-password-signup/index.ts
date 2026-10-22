import { optionsResponse } from "../_shared/cors.ts";
import { normalizeE164 } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost, rateLimitResponse } from "../_shared/http.ts";
import { enforceRateLimits, RateLimitExceededError, requestAddress } from "../_shared/rate-limit.ts";
import { serviceClient } from "../_shared/supabase.ts";

// Password registration is separate from proof of phone ownership. The
// server-owned marker prevents claiming pre-existing customer records by phone.
Deno.serve(async (request: Request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;
  if (Deno.env.get("ALLOW_PHONE_PASSWORD_SIGNUP") !== "true") {
    return errorResponse(request, 403, "password_signup_disabled", "Password registration is disabled.");
  }
  try {
    const input = await readJson<{
      phone: string; password: string; displayName: string; userType?: string;
    }>(request);
    if (!input || typeof input.phone !== "string" || typeof input.password !== "string" ||
        typeof input.displayName !== "string" || input.password.length < 8 ||
        input.password.length > 128 || input.displayName.trim().length < 2 ||
        input.displayName.trim().length > 120 ||
        (input.userType !== undefined && !["merchant", "customer"].includes(input.userType))) {
      return errorResponse(request, 422, "invalid_request", "Registration data is invalid.");
    }
    let phone: string;
    try { phone = normalizeE164(input.phone); }
    catch { return errorResponse(request, 422, "invalid_phone", "Phone must be a valid E.164 number."); }
    await enforceRateLimits([
      { scope: "password-signup-ip", subjectKey: requestAddress(request), maxHits: 10, windowSeconds: 3600 },
      { scope: "password-signup-phone", subjectKey: phone, maxHits: 3, windowSeconds: 3600 },
    ]);
    const admin = serviceClient();
    const { error } = await admin.auth.admin.createUser({
      phone,
      password: input.password,
      phone_confirm: true,
      app_metadata: { phone_verification_bypassed: true },
      user_metadata: {
        display_name: input.displayName.trim(),
        user_type: input.userType ?? "merchant",
      },
    });
    if (error) {
      if (error.code === "phone_exists" || error.code === "user_already_exists") {
        return errorResponse(request, 409, "account_exists", "هذا الرقم مسجل مسبقًا. سجّل دخولك.");
      }
      throw error;
    }
    return json(request, { success: true }, 201);
  } catch (error) {
    if (error instanceof RateLimitExceededError) return rateLimitResponse(request, error.retryAfterSeconds);
    console.error("phone_password_signup_error", error instanceof Error ? error.message : "unknown_error");
    return errorResponse(request, 500, "internal_error", "Unable to create the account.");
  }
});
