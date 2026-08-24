import { optionsResponse } from "../_shared/cors.ts";
import { errorResponse, json, readJson } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

// The edge appends the real client IP as the last x-forwarded-for entry;
// earlier entries are client-controlled and spoofable (fix-plan/03 step 5.1).
function clientIp(request: Request): string {
  const forwarded = request.headers.get("x-forwarded-for")
    ?.split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  return forwarded?.at(-1) ?? "unknown";
}

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  // POST with a JSON body is the preferred channel (keeps the code out of
  // proxy logs); GET is kept temporarily for one release for compatibility.
  if (request.method !== "POST" && request.method !== "GET") {
    return errorResponse(request, 405, "method_not_allowed", "POST is required");
  }
  try {
    let code: string | null;
    if (request.method === "POST") {
      try {
        const body = await readJson<{ code?: string }>(request);
        code = body.code?.trim().toUpperCase() ?? null;
      } catch {
        return errorResponse(request, 422, "invalid_code", "A valid verification code is required.");
      }
    } else {
      code = new URL(request.url).searchParams.get("code")?.trim().toUpperCase() ?? null;
    }
    if (!code || !/^[A-Z0-9-]{8,64}$/.test(code)) return errorResponse(request, 422, "invalid_code", "A valid verification code is required.");
    const admin = serviceClient();
    const ip = clientIp(request);
    const { error: ipLimitError } = await admin.rpc("service_consume_rate_limit", { p_scope: "statement-verification-ip", p_subject_key: ip, p_max_hits: 30, p_window_seconds: 3600 });
    if (ipLimitError) return errorResponse(request, 429, "rate_limited", "Too many verification requests. Try again later.");
    // Per-code limit blocks distributed enumeration even when IPs rotate.
    const { error: codeLimitError } = await admin.rpc("service_consume_rate_limit", { p_scope: "statement-verification-code", p_subject_key: code, p_max_hits: 20, p_window_seconds: 3600 });
    if (codeLimitError) return errorResponse(request, 429, "rate_limited", "Too many verification requests. Try again later.");
    const { data: statement, error } = await admin.from("statements").select("verification_code,created_at,period_from,period_to,currency_code,closing_balance,snapshot_sha256_hex,pdf_object_path").eq("verification_code", code).maybeSingle();
    if (error) throw error;
    if (!statement) return json(request, { valid: false });
    return json(request, { valid: true, generatedAt: statement.created_at, periodFrom: statement.period_from, periodTo: statement.period_to, currencyCode: statement.currency_code, closingBalance: statement.closing_balance, documentHash: statement.snapshot_sha256_hex, hasDocument: Boolean(statement.pdf_object_path) });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    return errorResponse(request, 500, message, "Unable to verify this statement.");
  }
});
