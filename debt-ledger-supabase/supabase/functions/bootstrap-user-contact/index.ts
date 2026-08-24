import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { encryptPhone, normalizeE164, phoneHash } from "../_shared/crypto.ts";
import { errorResponse, json, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

// نسخة مفتاح تشفير الهاتف الحالية تُقرأ من الإعدادات (PHONE_KEY_VERSION)
// وتطابق الافتراضي الخلفي encryption_key_version default 1 عند غيابها.
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
    const { user } = await requireUser(request);
    // تُستدعى بعد أول تحقق OTP ناجح عبر Supabase Phone Auth (Twilio Verify):
    // ناشترط هاتفاً موثقاً فعلياً (phone_confirmed_at) لا مجرد حقل phone.
    if (!user.phone || !user.phone_confirmed_at) {
      return errorResponse(request, 422, "phone_missing", "The authenticated user has no verified phone number.");
    }
    let phone: string;
    try {
      phone = normalizeE164(user.phone);
    } catch {
      return errorResponse(request, 422, "invalid_phone", "The authenticated user's phone number is not a valid E.164 number.");
    }
    const admin = serviceClient();
    const { data: customer, error: customerError } = await admin
      .from("customers").select("id").eq("user_id", user.id).maybeSingle();
    if (customerError) throw customerError;
    if (!customer) {
      return errorResponse(request, 404, "customer_not_found", "No customer record is linked to this user.");
    }
    const { error } = await admin.rpc("service_upsert_customer_contact", {
      p_customer_id: customer.id,
      p_phone_hash: await phoneHash(phone),
      p_phone_ciphertext: await encryptPhone(phone),
      p_phone_last4: phone.slice(-4),
      p_verified_at: new Date().toISOString(),
      p_key_version: phoneKeyVersion(),
    });
    if (error) throw error;
    return json(request, { customerId: customer.id, phoneLast4: phone.slice(-4) });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    if (message === "unauthorized") return errorResponse(request, 401, "unauthorized", "Authentication is required.");
    console.error("bootstrap_user_contact_error", message);
    return errorResponse(request, 500, "internal_error", "Unable to bootstrap the customer contact.");
  }
});
