import { deliverFcm, fcmPayload, permanentFcmFailure } from "./fcm.ts";
function assert(value: unknown, message: string) {
  if (!value) throw new Error(message);
}
Deno.test("Android payload preserves identity, string data, privacy and channel", () => {
  const payload = fcmPayload("test-token", {
    notification_id: "notice-1",
    user_id: "user-1",
    title: "سداد",
    body: "تم السداد",
    data: { entity_id: "entry-1", amount: 12.5, missing: null },
  }).message;
  assert(payload.data.user_id === "user-1", "recipient missing");
  assert(payload.data.notification_id === "notice-1", "notice id missing");
  assert(payload.data.amount === "12.5", "FCM data must be strings");
  assert(!("missing" in payload.data), "null values must be omitted");
  assert(
    payload.android.notification.visibility === "PRIVATE",
    "lock screen privacy",
  );
  assert(
    payload.android.notification.channel_id === "muthbat_updates",
    "Android channel mismatch",
  );
  assert(
    payload.android.notification.tag === "notice-1",
    "retries replace same tray notice",
  );
  assert(
    !permanentFcmFailure(new Error("timeout")),
    "transient errors must retry",
  );
});
Deno.test("FCM HTTP v1 refreshes OAuth and distinguishes invalid device tokens from temporary failure", async () => {
  const original = globalThis.fetch;
  const oldSa = Deno.env.get("FIREBASE_SERVICE_ACCOUNT"),
    oldProject = Deno.env.get("FCM_PROJECT_ID");
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const exported = await crypto.subtle.exportKey("pkcs8", keys.privateKey);
  Deno.env.set("FCM_PROJECT_ID", "test-project");
  Deno.env.set(
    "FIREBASE_SERVICE_ACCOUNT",
    JSON.stringify({
      project_id: "test-project",
      client_email: "test@example.test",
      private_key: `-----BEGIN PRIVATE KEY-----\n${
        btoa(String.fromCharCode(...new Uint8Array(exported)))
      }\n-----END PRIVATE KEY-----`,
    }),
  );
  let oauth = 0, send = 0;
  globalThis.fetch = (async (input, init) => {
    if (String(input).includes("oauth2")) {
      oauth++;
      return Response.json({ access_token: "test-bearer", expires_in: 3600 });
    }
    send++;
    const payload = JSON.parse(String(init?.body));
    assert(payload.message.token === "device-token", "incorrect target");
    if (send === 1) {
      return Response.json({
        error: { details: [{ errorCode: "UNREGISTERED" }] },
      }, { status: 404 });
    }
    return Response.json({
      name: "projects/test-project/messages/test-message",
    });
  }) as typeof fetch;
  try {
    const notice = {
      notification_id: "n",
      user_id: "u",
      title: "t",
      body: "b",
      data: {},
    };
    let invalid = false;
    try {
      await deliverFcm("device-token", notice);
    } catch (error) {
      invalid = permanentFcmFailure(error);
    }
    assert(invalid, "unregistered device must be disabled");
    await deliverFcm("device-token", notice);
    assert(oauth === 1 && send === 2, "OAuth token should be cached");
  } finally {
    globalThis.fetch = original;
    if (oldSa === undefined) Deno.env.delete("FIREBASE_SERVICE_ACCOUNT");
    else Deno.env.set("FIREBASE_SERVICE_ACCOUNT", oldSa);
    if (oldProject === undefined) Deno.env.delete("FCM_PROJECT_ID");
    else Deno.env.set("FCM_PROJECT_ID", oldProject);
  }
});
Deno.test("Missing Firebase credentials fail without sending", async () => {
  const old = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  Deno.env.delete("FIREBASE_SERVICE_ACCOUNT");
  try {
    let failed = false;
    try {
      await deliverFcm("test-token", {
        notification_id: "n",
        user_id: "u",
        title: "t",
        body: "b",
        data: {},
      });
    } catch (error) {
      failed = String(error).includes("configuration");
    }
    assert(failed, "missing credentials must fail closed");
  } finally {
    if (old) Deno.env.set("FIREBASE_SERVICE_ACCOUNT", old);
  }
});
