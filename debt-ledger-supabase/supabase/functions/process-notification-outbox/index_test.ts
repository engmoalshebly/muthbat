Deno.test("worker enforces auth and preferences and skips previously delivered devices", async () => {
  const originalServe = Deno.serve, originalFetch = globalThis.fetch;
  const env = {
    SUPABASE_URL: "https://example.test",
    SUPABASE_SERVICE_ROLE_KEY: "test-service-key",
    NOTIFICATION_WORKER_SECRET: "test-worker-secret",
    PUSH_PROVIDER: "fcm",
  };
  const previous = new Map(
    Object.keys(env).map((name) => [name, Deno.env.get(name)]),
  );
  let handler: (request: Request) => Promise<Response>;
  let enabled = false, calls = 0;
  const finishes: boolean[] = [];
  try {
    for (const [name, value] of Object.entries(env)) Deno.env.set(name, value);
    Deno.serve = ((callback: typeof handler) => {
      handler = callback;
      return {};
    }) as unknown as typeof Deno.serve;
    globalThis.fetch = (async (input, init) => {
      calls++;
      const url = String(input);
      let result: unknown;
      if (url.includes("service_claim_notification_batch")) {
        result = [{
          outbox_id: 1,
          notification_id: "notice",
          user_id: "user",
          notification_type: "ledger_created",
          title: "t",
          body: "b",
          data: {},
        }];
      } else if (url.includes("notification_preferences")) {
        result = {
          push_enabled: enabled,
          financial_enabled: true,
          disputes_enabled: true,
          reminders_enabled: true,
        };
      } else if (url.includes("device_push_tokens")) {
        result = [{ id: "device", push_token: "test-token" }];
      } else if (url.includes("service_notification_device_sent")) {
        result = true;
      } else if (url.includes("service_record_notification_delivery_attempt")) {
        result = null;
      } else if (url.includes("service_finish_notification")) {
        finishes.push(JSON.parse(String(init?.body)).p_sent);
        result = null;
      } else throw new Error(`Unexpected call ${url}`);
      return new Response(JSON.stringify(result), {
        headers: { "Content-Type": "application/json" },
      });
    }) as typeof fetch;
    await import("./index.ts");
    const request = (secret: string) =>
      new Request("https://example.test/worker", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-worker-secret": secret,
        },
        body: "{}",
      });
    const unauthorized = await handler!(request("wrong"));
    if (unauthorized.status !== 401 || calls !== 0) {
      throw new Error("Unauthorized worker did database work");
    }
    const disabled = await handler!(request(env.NOTIFICATION_WORKER_SECRET));
    if (disabled.status !== 200 || finishes[0] !== false) {
      throw new Error("Disabled preference reported push success");
    }
    enabled = true;
    const retry = await handler!(request(env.NOTIFICATION_WORKER_SECRET));
    if (retry.status !== 200 || finishes[1] !== true) {
      throw new Error("Previously sent device was not deduplicated");
    }
  } finally {
    Deno.serve = originalServe;
    globalThis.fetch = originalFetch;
    for (const [name, value] of previous) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
});
