import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { encryptPhone, phoneHash } from "../_shared/crypto.ts";
import { normalizeCustomerPhone } from "../_shared/customer-phone.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type DirectoryRequest = { requestId?: string; localCustomerId?: string; businessId: string; phone?: string; localDisplayName: string; localNote?: string; creditLimit?: number; defaultDueDays?: number; requestLink?: boolean };
const allowedRoles = ["owner", "admin", "accountant", "cashier"];

function phoneKeyVersion(): number {
  const raw = Deno.env.get("PHONE_KEY_VERSION");
  const parsed = raw ? Number.parseInt(raw, 10) : Number.NaN;
  return Number.isInteger(parsed) && parsed > 0 ? parsed : 1;
}

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;
  try {
    const { user, client } = await requireUser(request);
    const input = await readJson<DirectoryRequest>(request);
    if (!input.businessId || !input.localDisplayName?.trim()) return errorResponse(request, 422, "invalid_request", "businessId and localDisplayName are required.");
    if (input.localNote != null && (typeof input.localNote !== "string" || input.localNote.length > 500)) return errorResponse(request, 422, "invalid_note", "Customer note must not exceed 500 characters.");

    let phone: string | null = null;
    if (input.phone && input.phone.trim().length > 0) {
      try {
        phone = normalizeCustomerPhone(input.phone);
      } catch {
        return errorResponse(request, 422, "invalid_phone", "phone must be a valid number.");
      }
    }

    const admin = serviceClient();
    const { error: limitError } = await admin.rpc("service_consume_rate_limit", {
      p_scope: "customer-directory-user", p_subject_key: user.id, p_max_hits: 60, p_window_seconds: 3600,
    });
    if (limitError) return errorResponse(request, 429, "rate_limited", "Too many directory requests. Try again later.");

    // Membership is checked through the caller's authenticated session. This
    // keeps the authorization decision tied to the JWT and avoids depending
    // on service_role table-read grants in different Supabase environments.
    const { data: membership, error: membershipError } = await client
      .from("business_members")
      .select("role,status")
      .eq("business_id", input.businessId)
      .eq("user_id", user.id)
      .eq("status", "active")
      .maybeSingle();
    if (membershipError) throw membershipError;
    if (!membership || !allowedRoles.includes(membership.role)) return errorResponse(request, 403, "forbidden", "You cannot add customers to this business.");

    const requestId = input.requestId ?? (input.localCustomerId?.startsWith("cust-") ? input.localCustomerId.slice(5) : "");
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId)) {
      return errorResponse(request, 422, "invalid_request_id", "A stable UUID requestId is required.");
    }
    const contact: Record<string, unknown> = {};
    if (phone) {
      const encrypted = await encryptPhone(phone);
      contact.phone_hash = await phoneHash(phone);
      contact.phone_ciphertext = encrypted.startsWith("\\\\x") ? encrypted.slice(1) : encrypted;
      contact.phone_last4 = phone.slice(-4);
      contact.key_version = phoneKeyVersion();
    }
    const { error: prepareError } = await admin.rpc("service_prepare_customer_directory", {
      p_user_id: user.id, p_request_id: requestId,
      p_payload: { businessId: input.businessId, localDisplayName: input.localDisplayName.trim(),
        localNote: input.localNote?.trim() ?? null, creditLimit: input.creditLimit ?? null,
        defaultDueDays: input.defaultDueDays ?? null, requestLink: input.requestLink ?? false },
      p_contact: contact,
    });
    if (prepareError) throw prepareError;
    const { data, error } = await client.rpc("complete_customer_directory", { p_request_id: requestId });
    if (error) throw error;
    return json(request, data, 201);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    if (message === "unauthorized") return errorResponse(request, 401, "unauthorized", "Authentication is required.");
    if (message === "invalid_json") return errorResponse(request, 400, "invalid_json", "Request body must be valid JSON.");
    const code = typeof error === "object" && error !== null && "code" in error ? String(error.code) : "";
    if (["22023", "22P02", "23505"].includes(code)) return errorResponse(request, 422, "invalid_request", "راجع بيانات العميل أو تعارض رقم الهاتف.");
    if (code === "42501") return errorResponse(request, 403, "forbidden", "لا تملك صلاحية إضافة العميل.");
    return errorResponse(request, 500, "internal_error", "Unable to resolve this customer.");
  }
});
