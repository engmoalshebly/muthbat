import { optionsResponse } from "../_shared/cors.ts";
import { normalizeE164 } from "../_shared/crypto.ts";
import {
  errorResponse,
  json,
  rateLimitResponse,
  readJson,
  requirePost,
} from "../_shared/http.ts";
import {
  enforceRateLimits,
  RateLimitExceededError,
  requestAddress,
} from "../_shared/rate-limit.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { sendOpenWaText } from "../_shared/openwa.ts";

interface SendOtpRequest {
  phone: string;
  appName?: string;
}

/** Creates an OTP server-side and delivers it through the private OpenWA gateway. */
Deno.serve(async (request: Request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;

  try {
    const input = await readJson<SendOtpRequest>(request);
    if (
      !input || typeof input !== "object" || typeof input.phone !== "string"
    ) {
      return errorResponse(
        request,
        422,
        "invalid_phone",
        "Phone must be a valid E.164 number.",
      );
    }

    let phone: string;
    try {
      phone = normalizeE164(input.phone);
    } catch {
      return errorResponse(
        request,
        422,
        "invalid_phone",
        "Phone must be a valid E.164 number.",
      );
    }

    // Fail closed unless this project explicitly enables WhatsApp delivery.
    // This guard runs before rate-limit counters, challenge creation, or any
    // outbound request so old clients cannot trigger a message while disabled.
    if (Deno.env.get("WHATSAPP_OTP_ENABLED") !== "true") {
      return errorResponse(
        request,
        503,
        "otp_delivery_disabled",
        "WhatsApp verification is disabled.",
      );
    }

    const configuredBaseUrl = Deno.env.get("OPENWA_BASE_URL");
    const sessionId = Deno.env.get("OPENWA_SESSION_ID");
    const apiKey = Deno.env.get("OPENWA_API_KEY");
    if (!configuredBaseUrl || !sessionId || !apiKey) {
      return errorResponse(
        request,
        503,
        "otp_delivery_unavailable",
        "OTP delivery is not configured.",
      );
    }

    try {
      await enforceRateLimits([
        {
          scope: "auth-otp-request-ip",
          subjectKey: requestAddress(request),
          maxHits: 10,
          windowSeconds: 3600,
        },
        {
          scope: "auth-otp-request-phone",
          subjectKey: phone,
          maxHits: 5,
          windowSeconds: 3600,
        },
      ]);
    } catch (error) {
      if (error instanceof RateLimitExceededError) {
        return rateLimitResponse(request, error.retryAfterSeconds);
      }
      throw error;
    }

    const admin = serviceClient();
    const { data: challenge, error: challengeError } = await admin.rpc(
      "service_request_whatsapp_otp",
      { p_phone: phone },
    );
    if (challengeError || !challenge) {
      const limited =
        challengeError?.message.toLowerCase().includes("60 seconds") ?? false;
      return errorResponse(
        request,
        limited ? 429 : 400,
        limited ? "rate_limited" : "otp_request_failed",
        "Unable to create a verification code.",
      );
    }

    const revokeChallenge = async () => {
      await admin.rpc("service_revoke_whatsapp_otp", {
        p_challenge_id: challenge.challenge_id,
      });
    };
    // Supabase local runs inside Docker, while OpenWA runs on the host.
    const baseUrl = configuredBaseUrl.replace(
      /127\.0\.0\.1|localhost/,
      "host.docker.internal",
    );
    const appName = typeof input.appName === "string" && input.appName.trim()
      ? input.appName.trim().slice(0, 80)
      : "Muthbat";
    let delivery: Response;
    try {
      delivery = await sendOpenWaText({
        baseUrl,
        sessionId,
        apiKey,
        phone,
        text:
          `رمز التحقق في ${appName}: ${challenge.code}\nلا تشارك هذا الرمز مع أي شخص. صالح لمدة 5 دقائق.`,
      });
    } catch (error) {
      await revokeChallenge().catch(() => undefined);
      console.error("OpenWA OTP gateway unreachable", {
        phoneLast4: phone.slice(-4),
        error: error instanceof Error ? error.message : "unknown_error",
      });
      return errorResponse(
        request,
        503,
        "otp_delivery_unavailable",
        "OTP delivery is currently unavailable.",
      );
    }

    if (!delivery.ok) {
      // OpenWA uses 400 both for invalid payloads and inactive sessions.
      // Log only a bounded error category; never log the OTP, response body,
      // provider credentials, or the full recipient number.
      let providerError = "unknown";
      try {
        const payload = await delivery.json();
        const message = Array.isArray(payload?.message)
          ? payload.message.join(" ")
          : typeof payload?.message === "string" ? payload.message : "";
        if (/session.*(not active|not started)|start the session/i.test(message)) {
          providerError = "session_inactive";
        } else if (/chatId|text|validation|must be/i.test(message)) {
          providerError = "invalid_request";
        } else if (delivery.status === 400) {
          providerError = "bad_request";
        }
      } catch {
        // The response may be empty or non-JSON.
      }
      await revokeChallenge().catch(() => undefined);
      console.error("OpenWA OTP delivery failed", {
        status: delivery.status,
        providerError,
        phoneLast4: phone.slice(-4),
      });
      return errorResponse(
        request,
        502,
        "otp_delivery_failed",
        "OTP delivery failed. Please try again later.",
      );
    }

    return json(request, {
      success: true,
      challengeId: challenge.challenge_id,
      expiresInSeconds: 300,
    }, 201);
  } catch (error) {
    console.error(
      "send_whatsapp_otp_error",
      error instanceof Error ? error.message : "unknown_error",
    );
    return errorResponse(
      request,
      500,
      "internal_error",
      "Unable to send the verification code.",
    );
  }
});
