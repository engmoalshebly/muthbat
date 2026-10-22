Deno.test("disabled or unconfigured OTP never creates a challenge or sends a message", async () => {
  const originalServe = Deno.serve;
  const originalFetch = globalThis.fetch;
  const previous = new Map<string, string | undefined>();
  for (
    const [name, value] of Object.entries({
      WHATSAPP_OTP_ENABLED: "false",
      OPENWA_BASE_URL: "https://notify.example.test",
      OPENWA_SESSION_ID: "session",
      OPENWA_API_KEY: "",
    })
  ) {
    previous.set(name, Deno.env.get(name));
    Deno.env.set(name, value);
  }
  let handler: (request: Request) => Promise<Response>;
  let requests = 0;
  try {
    Deno.serve = ((callback: typeof handler) => {
      handler = callback;
      return {};
    }) as unknown as typeof Deno.serve;
    globalThis.fetch = (() => {
      requests++;
      throw new Error("Unexpected network call before delivery is configured");
    }) as typeof fetch;
    await import("./index.ts");
    const request = () =>
      new Request("https://example.test/send-whatsapp-otp", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ phone: "+967777123456" }),
      });
    const disabled = await handler!(request());
    if (disabled.status !== 503 || requests !== 0) {
      throw new Error("Disabled OTP performed work");
    }
    Deno.env.set("WHATSAPP_OTP_ENABLED", "true");
    const unconfigured = await handler!(request());
    if (unconfigured.status !== 503 || requests !== 0) {
      throw new Error("Missing gateway key consumed a challenge or rate limit");
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
