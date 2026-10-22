Deno.test("bypassed phone claims require the explicit staging opt-in", async () => {
  const originalFetch = globalThis.fetch, originalServe = Deno.serve;
  const previous = new Map<string, string | undefined>();
  const key = btoa(String.fromCharCode(...new Uint8Array(32).fill(7)));
  for (const [name, value] of Object.entries({ SUPABASE_URL: "https://example.test", SUPABASE_SERVICE_ROLE_KEY: "test-service-key", SUPABASE_ANON_KEY: "test-anon-key", ALLOW_STAGING_DIRECT_AUTH: "true", APP_ENV: "staging", ALLOW_STAGING_UNVERIFIED_PHONE_LINKS: "false", PHONE_HMAC_KEY: key, PHONE_ENCRYPTION_KEY: key })) {
    previous.set(name, Deno.env.get(name)); Deno.env.set(name, value);
  }
  let handler: (request: Request) => Promise<Response>;
  let bypass = true, confirmed = true, claims = 0, allowUnverifiedClaim = false;
  try {
    Deno.serve = ((callback: typeof handler) => { handler = callback; return {}; }) as unknown as typeof Deno.serve;
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(input instanceof Request ? input.url : input.toString());
      let data: unknown;
      if (url.pathname.endsWith("/auth/v1/user")) data = { id: "d1940000-0000-4000-8000-000000000001", phone: "967777123456", phone_confirmed_at: confirmed ? "2026-01-01T00:00:00Z" : null, app_metadata: { phone_verification_bypassed: bypass } };
      else if (url.pathname.endsWith("/customers")) data = { id: "customer" };
      else if (url.pathname.endsWith("/service_claim_customer_phone")) {
        claims++;
        const rawBody = typeof init?.body === "string"
          ? init.body
          : input instanceof Request ? await input.clone().text() : "{}";
        const body = JSON.parse(rawBody || "{}");
        allowUnverifiedClaim = body.p_allow_unverified_staging === true;
        data = "claimed-customer";
      }
      else throw new Error(`Unexpected request ${url}`);
      return new Response(JSON.stringify(data), { headers: { "content-type": "application/json" } });
    }) as typeof fetch;
    await import("./index.ts");
    const request = () => new Request("https://example.test/bootstrap-user-contact", { method: "POST", headers: { authorization: "Bearer test-token" } });
    const blocked = await handler!(request());
    if (blocked.status !== 403 || claims !== 0) throw new Error("Bypassed identity claimed records");
    bypass = false; confirmed = false;
    const unconfirmed = await handler!(request());
    if (unconfirmed.status !== 422 || claims !== 0) throw new Error("Unconfirmed identity claimed records");
    confirmed = true;
    bypass = true;
    Deno.env.set("ALLOW_STAGING_UNVERIFIED_PHONE_LINKS", "true");
    const stagingClaim = await handler!(request());
    if (stagingClaim.status !== 200 || Number(claims) !== 1 || !allowUnverifiedClaim) {
      throw new Error(`Explicit staging claim failed: ${await stagingClaim.text()}`);
    }
    Deno.env.set("APP_ENV", "prod");
    const productionBlocked = await handler!(request());
    if (productionBlocked.status !== 403 || Number(claims) !== 1) {
      throw new Error("Staging bypass was accepted outside staging");
    }
    Deno.env.set("APP_ENV", "staging");
    bypass = false;
    const result = await handler!(request());
    if (result.status !== 200 || Number(claims) !== 2) throw new Error(`Verified claim failed: ${await result.text()}`);
  } finally {
    Deno.serve = originalServe; globalThis.fetch = originalFetch;
    for (const [name, value] of previous) { if (value === undefined) Deno.env.delete(name); else Deno.env.set(name, value); }
  }
});
