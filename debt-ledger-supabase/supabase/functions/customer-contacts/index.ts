import { requireUser } from "../_shared/auth.ts";
import { optionsResponse } from "../_shared/cors.ts";
import { decryptPhone } from "../_shared/crypto.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;
  try {
    const { user, accessToken } = await requireUser(request);
    const input = await readJson<{ deviceId: string; businessId: string; customerIds: string[] }>(request);
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (!uuid.test(input.deviceId) || !uuid.test(input.businessId) || !Array.isArray(input.customerIds)
      || input.customerIds.length < 1 || input.customerIds.length > 100 || input.customerIds.some(id => typeof id !== 'string' || !uuid.test(id))) {
      return errorResponse(request,422,"invalid_request","Invalid contact batch.");
    }
    // requireUser verifies this exact token with Auth before its claims are used.
    const encoded = accessToken.split('.')[1].replace(/-/g,'+').replace(/_/g,'/');
    const session = JSON.parse(atob(encoded.padEnd(Math.ceil(encoded.length/4)*4,'='))).session_id;
    if (typeof session !== 'string' || !uuid.test(session)) return errorResponse(request,403,"forbidden","Active session required.");
    const admin = serviceClient();
    const { error: limitError } = await admin.rpc("service_consume_rate_limit", {
      p_scope:"customer-contacts-user",p_subject_key:user.id,p_max_hits:600,p_window_seconds:3600,
    });
    if (limitError) return errorResponse(request,429,"rate_limited","Try again later.");
    const { data, error } = await admin.rpc("service_read_customer_contacts", {
      p_user_id:user.id,p_session_id:session,p_device_id:input.deviceId,
      p_business_id:input.businessId,p_customer_ids:input.customerIds,
    });
    if (error) throw error;
    const contacts = await Promise.all((data ?? []).map(async (row: {business_customer_id:string;phone_ciphertext:string;encryption_key_version:number}) => ({
      businessCustomerId:row.business_customer_id,phone:await decryptPhone(row.phone_ciphertext,row.encryption_key_version),
    })));
    const response = json(request,{contacts});
    response.headers.set('Cache-Control','no-store');
    return response;
  } catch (error) {
    if (error instanceof Error && error.message === 'unauthorized') return errorResponse(request,401,'unauthorized','Authentication required.');
    const code = typeof error === 'object' && error !== null && 'code' in error ? String(error.code) : '';
    if (code === '42501') return errorResponse(request,403,'forbidden','Contact access denied.');
    // No phone, ciphertext, keys, or decrypted data may appear in logs/errors.
    return errorResponse(request,500,'contact_read_failed','Unable to load contacts.');
  }
});
