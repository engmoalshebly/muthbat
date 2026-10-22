type Notice = {
  notification_id: string;
  user_id: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
};
let cached: { token: string; until: number } | undefined;
class FcmError extends Error {
  constructor(public code: string) {
    super(`FCM: ${code}`);
  }
}
export function permanentFcmFailure(error: unknown): boolean {
  return error instanceof FcmError &&
    ["UNREGISTERED", "SENDER_ID_MISMATCH"].includes(error.code);
}
const b64 = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_")
    .replace(/=+$/, "");
async function accessToken(): Promise<string> {
  const sa = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT") ?? "{}");
  const project = Deno.env.get("FCM_PROJECT_ID");
  if (
    !sa.client_email || !sa.private_key || !project || sa.project_id !== project
  ) {
    throw new Error(
      "Firebase service account/project configuration missing or mismatched",
    );
  }
  if (cached && cached.until > Date.now() + 300000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: unknown) =>
    b64(new TextEncoder().encode(JSON.stringify(value)));
  const unsigned = `${encode({ alg: "RS256", typ: "JWT" })}.${
    encode({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    })
  }`;
  const der = Uint8Array.from(
    atob(sa.private_key.replace(/-----[^-]+-----|\s/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${unsigned}.${b64(new Uint8Array(signature))}`,
    }),
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) {
    throw new Error(`Firebase OAuth failed (${response.status})`);
  }
  const body = await response.json();
  if (typeof body.access_token !== "string") {
    throw new Error("Invalid Firebase OAuth response");
  }
  cached = {
    token: body.access_token,
    until: Date.now() + Number(body.expires_in ?? 3600) * 1000,
  };
  return cached.token;
}
export function fcmPayload(token: string, notice: Notice) {
  return {
    message: {
      token,
      notification: { title: notice.title, body: notice.body },
      data: Object.fromEntries(
        Object.entries({
          ...notice.data,
          notification_id: notice.notification_id,
          user_id: notice.user_id,
        }).filter(([, v]) => v != null).map((
          [k, v],
        ) => [k, typeof v === "string" ? v : JSON.stringify(v)]),
      ),
      android: {
        priority: "HIGH",
        ttl: "86400s",
        notification: {
          channel_id: "muthbat_updates",
          icon: "ic_stat_notification",
          sound: "default",
          tag: notice.notification_id,
          visibility: "PRIVATE",
          default_vibrate_timings: true,
        },
      },
    },
  };
}
export async function deliverFcm(
  token: string,
  notice: Notice,
): Promise<unknown> {
  const bearer = await accessToken();
  const project = Deno.env.get("FCM_PROJECT_ID");
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${project}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${bearer}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(fcmPayload(token, notice)),
      signal: AbortSignal.timeout(15000),
    },
  );
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401) cached = undefined;
    const detail = body.error?.details?.find((d: { errorCode?: string }) =>
      d.errorCode
    );
    throw new FcmError(
      detail?.errorCode ?? body.error?.status ?? `HTTP_${response.status}`,
    );
  }
  if (typeof body.name !== "string") {
    throw new Error("FCM response missing message name");
  }
  return { name: body.name };
}
