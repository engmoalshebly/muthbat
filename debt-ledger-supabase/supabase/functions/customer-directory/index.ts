import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { encryptPhone, normalizeE164, phoneHash } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type DirectoryRequest = { businessId: string; phone?: string; localDisplayName: string; creditLimit?: number; defaultDueDays?: number; requestLink?: boolean };
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

    let phone: string | null = null;
    if (input.phone && input.phone.trim().length > 0) {
      try {
        const raw = input.phone.trim();
        phone = raw.startsWith("+") ? raw : (raw.startsWith("967") ? `+${raw}` : `+967${raw}`);
        phone = normalizeE164(phone);
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

    // No phone means there is no directory/PII operation to perform. Use the
    // authenticated atomic command directly; this also keeps queued offline
    // customer commands independent from service-role table grants.
    if (!phone) {
      const { data: businessCustomerId, error: directError } = await client.rpc("create_business_customer_direct", {
        p_business_id: input.businessId,
        p_local_display_name: input.localDisplayName.trim(),
        p_credit_limit: input.creditLimit ?? null,
        p_default_due_days: input.defaultDueDays ?? null,
      });
      if (directError || !businessCustomerId) throw directError ?? new Error("business_customer_create_failed");
      return json(request, {
        businessCustomerId,
        linkRequestId: null,
        isRegistered: false,
        phoneLast4: null,
        globalCode: null,
      }, 201);
    }

    let customer: { customer_id: string; user_id: string | null; global_code: string; phone_last4: string | null } | undefined;

    if (phone) {
      const hash = await phoneHash(phone);
      const { data: matches, error: lookupError } = await admin.rpc("service_resolve_customer_phone", {
        p_phone_hash: hash, p_phone_ciphertext: await encryptPhone(phone),
        p_phone_last4: phone.slice(-4), p_key_version: phoneKeyVersion(),
      });
      if (lookupError) throw lookupError;
      customer = matches?.[0];
      if (!customer) throw new Error("customer_resolve_failed");
    } else {
      const { data: created, error: createError } = await admin.from("customers").insert({}).select("id,user_id,global_code").single();
      if (createError || !created) throw createError ?? new Error("customer_create_failed");
      customer = { customer_id: created.id, user_id: null, global_code: created.global_code, phone_last4: null };
    }

    // A phone may identify one global customer, but the same business must
    // never receive a second active relationship for that customer.
    const { data: existingBusinessCustomer, error: existingError } = await client
      .from("business_customers")
      .select("id,is_archived")
      .eq("business_id", input.businessId)
      .eq("customer_id", customer.customer_id)
      .maybeSingle();
    if (existingError) throw existingError;
    if (existingBusinessCustomer && existingBusinessCustomer.is_archived !== true) {
      return errorResponse(request, 409, "customer_exists", "This phone number is already registered for this business.");
    }

    const { data: businessCustomerId, error: addError } = await client.rpc("add_business_customer", {
      p_business_id: input.businessId, p_customer_id: customer.customer_id, p_local_display_name: input.localDisplayName.trim(),
      p_credit_limit: input.creditLimit ?? null, p_default_due_days: input.defaultDueDays ?? null,
    });
    if (addError || !businessCustomerId) throw addError ?? new Error("business_customer_create_failed");

    let linkRequestId: string | null = null;
    if (input.requestLink && customer.user_id) {
      const { data, error } = await client.rpc("request_customer_link", { p_business_customer_id: businessCustomerId });
      if (error) throw error;
      linkRequestId = data;
    }
    return json(request, { businessCustomerId, linkRequestId, isRegistered: Boolean(customer.user_id), phoneLast4: customer.phone_last4, globalCode: customer.global_code }, 201);
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    if (message === "unauthorized") return errorResponse(request, 401, "unauthorized", "Authentication is required.");
    if (message === "invalid_json") return errorResponse(request, 400, "invalid_json", "Request body must be valid JSON.");
    console.error("customer_directory_error", message);
    return errorResponse(request, 500, "internal_error", "Unable to resolve this customer.");
  }
});
