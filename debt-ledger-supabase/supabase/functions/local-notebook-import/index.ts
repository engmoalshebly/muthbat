import { optionsResponse } from "../_shared/cors.ts";
import { requireUser } from "../_shared/auth.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { prepareNotebook } from "./prepare.ts";

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const methodError = requirePost(request);
  if (methodError) return methodError;
  try {
    const { user, client } = await requireUser(request);
    const input = await readJson<{ action?: string; notebook?: Record<string, unknown> }>(request);
    if (input.action === "capabilities") {
      // Exercise the same phone keys before the device freezes its notebook.
      await prepareNotebook({ owner_id: user.id, customers: [
        { id: "probe", name: "probe", phone: "+967700000000" },
      ], entries: [] }, user.id);
      if (input.notebook) await prepareNotebook(input.notebook, user.id);
      const { data, error } = await client.rpc("local_notebook_import_version");
      if (error) throw error;
      return json(request, { version: data });
    }
    if (!input.notebook) throw new Error("invalid_notebook");
    const admin = serviceClient();
    const { error: limitError } = await admin.rpc("service_consume_rate_limit", {
      p_scope: "local-notebook-import-user", p_subject_key: user.id,
      p_max_hits: 30, p_window_seconds: 3600,
    });
    if (limitError) return errorResponse(request, 429, "rate_limited", "حاول نقل الدفتر لاحقًا.");
    const prepared = await prepareNotebook(input.notebook, user.id);
    const { data: token, error: prepareError } = await admin.rpc("service_prepare_local_notebook_import", {
      p_user_id: user.id, p_notebook: prepared.notebook, p_contacts: prepared.contacts,
      p_original_notebook: input.notebook,
    });
    if (prepareError) throw prepareError;
    // The actual import runs with the user's verified JWT, not an impersonated
    // auth.uid(). Resolving contacts and creating the ledger are one transaction.
    const { data, error } = await client.rpc("import_prepared_local_notebook", { p_token: token });
    if (error) throw error;
    return json(request, data);
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    if (message === "unauthorized") return errorResponse(request, 401, "unauthorized", "سجّل الدخول لاستكمال النقل.");
    if (["invalid_notebook", "invalid_phone", "invalid_json", "duplicate_phone"].includes(message)) {
      return errorResponse(request, 422, message, message === "duplicate_phone"
        ? "يوجد أكثر من عميل برقم الهاتف نفسه. راجع الأرقام قبل النقل."
        : "راجع بيانات العملاء وأرقام هواتفهم قبل النقل.");
    }
    // Never log snapshots, contact ciphertext, or database error details (PII).
    const code = typeof error === "object" && error !== null && "code" in error ? String(error.code) : "";
    if (["22023", "22P02", "23505"].includes(code)) {
      return errorResponse(request, 422, "import_conflict", "تعذر نقل الدفتر بسبب بيانات غير صالحة أو تعارض في السجل السابق. لم تُنشأ نسخة جزئية.");
    }
    return errorResponse(request, 500, "import_unavailable", "تعذر إكمال النقل. أعد المحاولة بالحساب نفسه؛ دفترك محفوظ.");
  }
});
