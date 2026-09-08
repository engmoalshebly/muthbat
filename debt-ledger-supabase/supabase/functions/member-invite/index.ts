import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { normalizeE164 } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type InviteRequest = {
  businessId: string;
  phone?: string;
  targetUserId?: string;
  role: "admin" | "accountant" | "cashier" | "collector" | "viewer";
};

const allowedRoles = ["admin", "accountant", "cashier", "collector", "viewer"];
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * A merchant can invite with the employee's registered phone, without seeing
 * auth.users or handling a UUID. The response intentionally never reveals
 * whether a different phone is registered.
 */
Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;

  try {
    const { user, client } = await requireUser(request);
    const input = await readJson<InviteRequest>(request);
    if (!input.businessId || !allowedRoles.includes(input.role)) {
      return errorResponse(request, 422, "invalid_request", "businessId and a valid role are required.");
    }

    const { data: membership, error: membershipError } = await client
      .from("business_members")
      .select("role,status")
      .eq("business_id", input.businessId)
      .eq("user_id", user.id)
      .eq("status", "active")
      .maybeSingle();
    if (membershipError) throw membershipError;
    if (!membership || !["owner", "admin"].includes(membership.role)) {
      return errorResponse(request, 403, "forbidden", "You cannot invite employees to this business.");
    }

    let targetUserId = input.targetUserId?.trim() ?? "";
    if (input.phone?.trim()) {
      let phone: string;
      try {
        const raw = input.phone.trim();
        phone = normalizeE164(raw.startsWith("+") ? raw : (raw.startsWith("967") ? `+${raw}` : `+967${raw}`));
      } catch {
        return errorResponse(request, 422, "invalid_phone", "phone must be a valid number.");
      }
      const admin = serviceClient();
      const { error: limitError } = await admin.rpc("service_consume_rate_limit", {
        p_scope: "member-invite-user", p_subject_key: user.id, p_max_hits: 30, p_window_seconds: 3600,
      });
      if (limitError) return errorResponse(request, 429, "rate_limited", "Too many invitation requests. Try again later.");
      const { data: matches, error: lookupError } = await admin.rpc("service_find_auth_user_by_phone", { p_phone: phone });
      if (lookupError) throw lookupError;
      targetUserId = Array.isArray(matches) ? String(matches[0]?.user_id ?? "") : "";
      if (!targetUserId) {
        return errorResponse(request, 422, "employee_not_registered", "The employee must create and verify their account before receiving an invitation.");
      }
    }

    if (!uuidPattern.test(targetUserId)) {
      return errorResponse(request, 422, "invalid_employee", "A valid employee phone number is required.");
    }
    const { data: inviteId, error: inviteError } = await client.rpc("invite_business_member", {
      p_business_id: input.businessId,
      p_target_user_id: targetUserId,
      p_role: input.role,
    });
    if (inviteError || !inviteId) throw inviteError ?? new Error("invite_failed");
    return json(request, { inviteId }, 201);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    if (message === "unauthorized") return errorResponse(request, 401, "unauthorized", "Authentication is required.");
    console.error("member_invite_error", message);
    return errorResponse(request, 500, "internal_error", "Unable to send the invitation.");
  }
});
