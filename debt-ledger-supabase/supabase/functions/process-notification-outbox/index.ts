import { optionsResponse } from "../_shared/cors.ts";
import { requireWorkerSecret } from "../_shared/auth.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { deliverFcm, permanentFcmFailure } from "../_shared/fcm.ts";

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;
  const method = requirePost(request);
  if (method) return method;
  try {
    requireWorkerSecret(request, "NOTIFICATION_WORKER_SECRET");
    if (Deno.env.get("PUSH_PROVIDER") !== "fcm") {
      throw new Error("PUSH_PROVIDER must be fcm for Android production");
    }
    const input = await readJson<{ limit?: number }>(request).catch(
      () => ({} as { limit?: number }),
    );
    const limit = Number.isFinite(input.limit)
      ? Math.max(1, Math.min(input.limit!, 50))
      : 25;
    const admin = serviceClient();
    const { data: jobs, error } = await admin.rpc(
      "service_claim_notification_batch",
      { p_limit: limit },
    );
    if (error) throw error;
    let completed = 0, retried = 0;
    for (const notice of jobs ?? []) {
      try {
        const { data: prefs, error: prefError } = await admin.from(
          "notification_preferences",
        ).select("*").eq("user_id", notice.user_id).maybeSingle();
        if (prefError) throw prefError;
        const type = notice.notification_type as string;
        const disabled = prefs && (!prefs.push_enabled ||
          (["ledger_created", "ledger_confirmed"].includes(type) &&
            !prefs.financial_enabled) ||
          (type.startsWith("dispute") || type === "ledger_disputed" ||
              notice.data?.entity_type === "dispute") &&
            !prefs.disputes_enabled ||
          (["reminder", "payment_due"].includes(type) &&
            !prefs.reminders_enabled));
        const { data: tokens, error: tokenError } = await admin.from(
          "device_push_tokens",
        ).select("id,push_token").eq("user_id", notice.user_id).eq(
          "platform",
          "android",
        ).eq("is_active", true);
        if (tokenError) throw tokenError;
        let sent = false;
        const failures: string[] = [];
        if (disabled || notice.data?.push === false || !tokens?.length) {
          const { error: skipError } = await admin.rpc(
            "service_record_notification_delivery_attempt",
            {
              p_outbox_id: notice.outbox_id,
              p_provider: "fcm",
              p_device_token_id: null,
              p_status: "skipped",
              p_provider_response: {
                reason: disabled
                  ? "user_preferences"
                  : notice.data?.push === false
                  ? "in_app_only"
                  : "no_active_android_device",
              },
            },
          );
          if (skipError) throw skipError;
        }
        if (!disabled && notice.data?.push !== false) {
          for (const token of tokens ?? []) {
            const { data: previous, error: previousError } = await admin.rpc(
              "service_notification_device_sent",
              { p_outbox_id: notice.outbox_id, p_device_token_id: token.id },
            );
            if (previousError) throw previousError;
            if (previous) {
              sent = true;
              continue;
            }
            try {
              const result = await deliverFcm(token.push_token, notice);
              const { error: recordError } = await admin.rpc(
                "service_record_notification_delivery_attempt",
                {
                  p_outbox_id: notice.outbox_id,
                  p_provider: "fcm",
                  p_device_token_id: token.id,
                  p_status: "sent",
                  p_provider_response: result,
                },
              );
              if (recordError) throw recordError;
              sent = true;
            } catch (error) {
              const message = error instanceof Error
                ? error.message
                : "push_failed";
              const permanent = permanentFcmFailure(error);
              if (permanent) {
                const { error: deactivateError } = await admin.from(
                  "device_push_tokens",
                ).update({ is_active: false }).eq("id", token.id);
                if (deactivateError) throw deactivateError;
              } else failures.push(message);
              const { error: recordError } = await admin.rpc(
                "service_record_notification_delivery_attempt",
                {
                  p_outbox_id: notice.outbox_id,
                  p_provider: "fcm",
                  p_device_token_id: token.id,
                  p_status: "failed",
                  p_error: message,
                },
              );
              if (recordError) throw recordError;
            }
          }
        }
        if (failures.length) throw new Error(failures.join(" | "));
        const { error: finishError } = await admin.rpc(
          "service_finish_notification",
          { p_outbox_id: notice.outbox_id, p_sent: sent },
        );
        if (finishError) throw finishError;
        completed++;
      } catch (error) {
        const { error: failError } = await admin.rpc(
          "service_fail_notification",
          {
            p_outbox_id: notice.outbox_id,
            p_error: error instanceof Error ? error.message : "push_failed",
          },
        );
        if (failError) throw failError;
        retried++;
      }
    }
    return json(request, {
      claimed: jobs?.length ?? 0,
      completed,
      retried,
      provider: "fcm",
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown_error";
    return errorResponse(
      request,
      message === "unauthorized_worker" ? 401 : 500,
      message,
      "Unable to process notification outbox.",
    );
  }
});
