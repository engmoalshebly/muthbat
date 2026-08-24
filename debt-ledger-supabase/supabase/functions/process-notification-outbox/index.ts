import { optionsResponse } from "../_shared/cors.ts";
import { requireWorkerSecret } from "../_shared/auth.ts";
import { errorResponse, json, readJson, requirePost } from "../_shared/http.ts";
import { serviceClient } from "../_shared/supabase.ts";

type WorkerRequest = { limit?: number };
type Notification = {
  outbox_id: number;
  notification_id: string;
  user_id: string;
  notification_type: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
};

type DeviceToken = {
  id: string;
  push_token: string;
  platform: string;
  is_active: boolean;
};

// 1. Deliver via Expo Push API
async function deliverExpo(token: string, notification: Notification): Promise<unknown> {
  const endpoint = Deno.env.get("EXPO_PUSH_ENDPOINT") ?? "https://exp.host/--/api/v2/push/send";
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      to: token,
      sound: "default",
      title: notification.title,
      body: notification.body,
      data: notification.data ?? {},
    }),
  });

  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`Expo provider returned ${response.status}: ${JSON.stringify(body)}`);
  }
  return body;
}

// 2. Deliver via Firebase Cloud Messaging (FCM Legacy or HTTP v1 endpoint)
async function deliverFcm(token: string, notification: Notification): Promise<unknown> {
  const serverKey = Deno.env.get("FCM_SERVER_KEY");
  const projectId = Deno.env.get("FCM_PROJECT_ID");

  if (serverKey) {
    // Legacy FCM HTTP Protocol
    const response = await fetch("https://fcm.googleapis.com/fcm/send", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `key=${serverKey}`,
      },
      body: JSON.stringify({
        to: token,
        notification: {
          title: notification.title,
          body: notification.body,
          sound: "default",
        },
        data: notification.data ?? {},
        priority: "high",
      }),
    });

    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(`FCM provider returned ${response.status}: ${JSON.stringify(body)}`);
    }
    return body;
  } else if (projectId) {
    // FCM HTTP v1 (Requires Bearer OAuth token or fallback)
    const bearerToken = Deno.env.get("FCM_BEARER_TOKEN");
    if (!bearerToken) {
      throw new Error("Missing FCM_BEARER_TOKEN or FCM_SERVER_KEY for FCM delivery.");
    }

    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${bearerToken}`,
        },
        body: JSON.stringify({
          message: {
            token: token,
            notification: {
              title: notification.title,
              body: notification.body,
            },
            data: Object.fromEntries(
              Object.entries(notification.data ?? {}).map(([k, v]) => [k, String(v)]),
            ),
          },
        }),
      },
    );

    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(`FCM v1 provider returned ${response.status}: ${JSON.stringify(body)}`);
    }
    return body;
  } else {
    throw new Error("FCM provider configured but no FCM_SERVER_KEY or FCM_PROJECT_ID found.");
  }
}

Deno.serve(async (request) => {
  const preflight = optionsResponse(request);
  if (preflight) return preflight;

  const methodError = requirePost(request);
  if (methodError) return methodError;

  try {
    requireWorkerSecret(request);
    const workerRequest = await readJson<WorkerRequest>(request).catch(() => ({} as WorkerRequest));
    const limit = workerRequest.limit ?? 50;
    const admin = serviceClient();

    // 1. Claim batch of queued notifications atomically with lock
    const { data: jobs, error } = await admin.rpc("service_claim_notification_batch", {
      p_limit: Math.max(1, Math.min(limit, 100)),
    });

    if (error) throw error;

    let completed = 0;
    let retried = 0;
    const configuredProvider = Deno.env.get("PUSH_PROVIDER") ?? "in_app";

    for (const notification of (jobs ?? []) as Notification[]) {
      try {
        // 2. Fetch registered active push tokens for this user
        const { data: tokens, error: tokenError } = await admin
          .from("device_push_tokens")
          .select("id,push_token,platform,is_active")
          .eq("user_id", notification.user_id)
          .eq("is_active", true);

        if (tokenError) throw tokenError;

        const activeTokens = (tokens ?? []) as DeviceToken[];

        if (activeTokens.length === 0 || configuredProvider === "in_app" || configuredProvider === "mock") {
          // In-App only or Mock mode
          for (const token of activeTokens) {
            await admin.rpc("service_record_notification_delivery_attempt", {
              p_outbox_id: notification.outbox_id,
              p_provider: configuredProvider,
              p_device_token_id: token.id,
              p_status: "skipped",
              p_provider_response: { reason: "in_app_or_mock_provider" },
            });
          }
        } else {
          // Dispatch to the configured push provider with per-token failure
          // isolation: a single failing token must NOT fail the whole
          // notification. Failing the job after some tokens already received
          // the push causes a retry that duplicates the notification on those
          // devices (no idempotency exists at (outbox_id, device_token_id)).
          let sentCount = 0;
          let failedCount = 0;
          const failures: string[] = [];

          for (const token of activeTokens) {
            try {
              let providerResponse: unknown = null;
              if (configuredProvider === "fcm") {
                providerResponse = await deliverFcm(token.push_token, notification);
              } else if (configuredProvider === "expo") {
                providerResponse = await deliverExpo(token.push_token, notification);
              } else {
                throw new Error(`Unsupported push provider: ${configuredProvider}`);
              }

              await admin.rpc("service_record_notification_delivery_attempt", {
                p_outbox_id: notification.outbox_id,
                p_provider: configuredProvider,
                p_device_token_id: token.id,
                p_status: "sent",
                p_provider_response: providerResponse,
              });
              sentCount++;
            } catch (tokenError) {
              const errorMessage = tokenError instanceof Error ? tokenError.message : "push_failed";
              await admin.rpc("service_record_notification_delivery_attempt", {
                p_outbox_id: notification.outbox_id,
                p_provider: configuredProvider,
                p_device_token_id: token.id,
                p_status: "failed",
                p_error: errorMessage,
              });
              failedCount++;
              failures.push(`${token.id}: ${errorMessage}`);
            }
          }

          if (sentCount === 0 && failedCount > 0) {
            // No device received anything, so retrying the whole notification
            // cannot duplicate a delivery. Throw to enter the backoff path.
            throw new Error(`all_token_deliveries_failed: ${failures.join(" | ")}`);
          }
          // Partial or full success: the user received the notification on at
          // least one device. Complete the job; failed tokens remain recorded
          // as failed delivery attempts for diagnostics.
        }

        // 3. Mark notification outbox job as completed
        const { error: completeError } = await admin.rpc("service_complete_notification", {
          p_outbox_id: notification.outbox_id,
        });

        if (completeError) throw completeError;
        completed++;
      } catch (jobError) {
        const errorMessage = jobError instanceof Error ? jobError.message : "notification_failed";
        await admin.rpc("service_fail_notification", {
          p_outbox_id: notification.outbox_id,
          p_error: errorMessage,
        });
        retried++;
      }
    }

    return json(request, {
      claimed: (jobs ?? []).length,
      completed,
      retried,
      provider: configuredProvider,
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
