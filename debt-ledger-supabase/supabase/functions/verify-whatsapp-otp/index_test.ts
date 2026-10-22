// All HTTP calls are intercepted: no OTP delivery or real account writes.
Deno.test("only a consumed OTP upgrades a bypassed account and preserves app metadata", async () => {
  const originalFetch = globalThis.fetch;
  const originalServe = Deno.serve;
  const env = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries({ SUPABASE_URL: "https://example.test", SUPABASE_SERVICE_ROLE_KEY: "test-service-key" })) {
    env.set(key, Deno.env.get(key));
    Deno.env.set(key, value);
  }
  let handler: (request: Request) => Promise<Response>;
  let validOtp = false;
  const updates: Record<string, unknown>[] = [];
  const userId = "d1940000-0000-4000-8000-000000000001";
  try {
    Deno.serve = ((callback: typeof handler) => { handler = callback; return {}; }) as unknown as typeof Deno.serve;
    globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : input.toString());
      let data: unknown;
      if (url.pathname.endsWith("/service_consume_rate_limit")) data = null;
      else if (url.pathname.endsWith("/service_verify_whatsapp_otp")) data = validOtp;
      else if (url.pathname.endsWith("/service_find_auth_user_by_phone")) data = [{ user_id: userId }];
      else if (url.pathname.endsWith(`/admin/users/${userId}`)) {
        if (init?.method === "PUT") updates.push(JSON.parse(init.body as string));
        data = { id: userId, app_metadata: { phone_verification_bypassed: true, preserved: "value" } };
      } else throw new Error(`Unexpected request ${url}`);
      return Promise.resolve(new Response(JSON.stringify(data), { headers: { "content-type": "application/json" } }));
    }) as typeof fetch;
    await import("./index.ts");
    const request = () => new Request("https://example.test/verify-whatsapp-otp", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ challengeId: "d1940000-0000-4000-8000-000000000002", code: "123456", phone: "+967777123456", password: "new-test-password", action: "recovery" }),
    });
    const invalid = await handler!(request());
    if (invalid.status !== 400 || updates.length !== 0) throw new Error("Invalid OTP changed account");
    validOtp = true;
    const valid = await handler!(request());
    if (valid.status !== 200) throw new Error(`Valid OTP failed: ${await valid.text()}`);
    const metadata = updates[0]?.app_metadata as Record<string, unknown>;
    if (Number(updates.length) !== 1 || metadata.phone_verification_bypassed !== false || metadata.preserved !== "value" || updates[0].phone_confirm !== true) throw new Error("OTP upgrade lost account metadata or ownership state");
  } finally {
    Deno.serve = originalServe;
    globalThis.fetch = originalFetch;
    for (const [key, value] of env) { if (value === undefined) Deno.env.delete(key); else Deno.env.set(key, value); }
  }
});
